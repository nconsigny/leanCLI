import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.State
import LeanCli.Encoding.Json
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Server
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.SphincsHybridStore

/-!
# Daemon server: `account.*` RPC family

Default-account state file management (process-user state, owned by the
daemon so the CLI stays a thin forwarder) plus the unified
`account.list` projection over EOA + SPHINCS+ stores.

Four methods:
  account.getDefault / setDefault / clearDefault
  account.list
-/

namespace LeanCli.Daemon.Server.AccountRpc

open LeanCli.Encoding.Json
open LeanCli.Keystore.Tpm2Runtime
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `account.*` JSON-RPC method. -/
def dispatch (_cfg : Config) (_state : LeanCli.Daemon.State.Shared)
    (_notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "account.getDefault" =>
      -- Why: the default account is process-user state, not chain state, but
      -- the daemon is the right owner because the CLI is supposed to be a
      -- thin RPC forwarder (CLAUDE.md). File lives at
      -- `$XDG_CONFIG_HOME/leancli/default-account.txt` falling back to
      -- `~/.config/leancli/default-account.txt`. Returns `{ name: null }`
      -- when unset; never throws, so first-run callers don't have to special
      -- case missing files.
      let path ← defaultAccountPathIO
      if ← path.pathExists then
        let raw ← try IO.FS.readFile path catch _ => pure ""
        let trimmed := raw.trimAscii.toString
        if trimmed.isEmpty then
          pure <| .ok <| .obj #[("name", .null)]
        else
          pure <| .ok <| .obj #[("name", .str trimmed)]
      else
        pure <| .ok <| .obj #[("name", .null)]
  | "account.setDefault" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          let path ← defaultAccountPathIO
          match path.parent with
          | some parent => try IO.FS.createDirAll parent catch _ => pure ()
          | none => pure ()
          IO.FS.writeFile path (name ++ "\n")
          pure <| .ok <| .obj #[("ok", .bool true), ("name", .str name)]
  | "account.clearDefault" =>
      let path ← defaultAccountPathIO
      if ← path.pathExists then
        try IO.FS.removeFile path catch _ => pure ()
      pure <| .ok <| .obj #[("ok", .bool true)]
  | "account.list" =>
      -- Why: unified replacement for the CLI's three combined-list helpers
      -- (`printAccountListNames`, `printAccountListTypedNames`,
      -- `printAccountListIndices`). Each returns a different projection of
      -- the same data; consolidating to one daemon RPC removes ~80 LoC of
      -- near-duplicate CLI code.
      let eoaNames ← LeanCli.Wallet.EoaStore.list
      let mut entries : Array Json := #[]
      for name in eoaNames do
        match ← LeanCli.Wallet.EoaStore.load name with
        | .ok record =>
            let indices : Array Json :=
              (recordAccounts record).map (fun a => .num (Int.ofNat a.index))
            entries := entries.push <| .obj #[
              ("type",    .str "eoa"),
              ("name",    .str record.name),
              ("address", .str record.address),
              ("indices", .arr indices)
            ]
        | .error _ => pure ()
      -- SPHINCS- hybrid smart accounts. Each slot's identity is its
      -- CREATE2 smart-account address; we surface it as `address` so
      -- the TUI / CLI can treat it uniformly with EOA rows. When
      -- the counterfactual hasn't been computed yet the field stays
      -- empty — the SphincsAccountsHub detail view exposes "Compute
      -- counterfactual address" to populate it.
      try
        let sphincsNames ← LeanCli.Wallet.SphincsHybridStore.listSlotNames
        for name in sphincsNames do
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .ok rec =>
              entries := entries.push <| .obj #[
                ("type",     .str "sphincs"),
                ("name",     .str rec.name),
                ("address",  .str (rec.smartAccountAddress.getD "")),
                ("paramSet", .str rec.paramSet.toString),
                ("chainId",  .num (Int.ofNat rec.chainId)),
                ("owner",    .str rec.ownerAddress)
              ]
          | .error _ => pure ()
      catch _ => pure ()
      pure (.ok (.obj #[("accounts", .arr entries)]))
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.AccountRpc
