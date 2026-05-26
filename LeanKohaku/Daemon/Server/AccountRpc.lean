import LeanKohaku.Daemon.Server.Core
import LeanKohaku.Daemon.Server.Helpers
import LeanKohaku.Daemon.State
import LeanKohaku.Encoding.Json
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.RPC.Server
import LeanKohaku.Wallet.EoaStore
import LeanKohaku.Wallet.SphincsHybridStore

/-!
# Daemon server: `account.*` RPC family

Default-account state file management (process-user state, owned by the
daemon so the CLI stays a thin forwarder) plus the unified
`account.list` projection over EOA + TPM2 + SPHINCS+ stores.

Four methods:
  account.getDefault / setDefault / clearDefault
  account.list
-/

namespace LeanKohaku.Daemon.Server.AccountRpc

open LeanKohaku.Encoding.Json
open LeanKohaku.Keystore.Tpm2Runtime
open LeanKohaku.RPC.Server
open LeanKohaku.Daemon.Server

/-- Handle every `account.*` JSON-RPC method. -/
def dispatch (_cfg : Config) (_state : LeanKohaku.Daemon.State.Shared)
    (_notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "account.getDefault" =>
      -- Why: the default account is process-user state, not chain state, but
      -- the daemon is the right owner because the CLI is supposed to be a
      -- thin RPC forwarder (CLAUDE.md). File lives at
      -- `$XDG_CONFIG_HOME/leankohaku/default-account.txt` falling back to
      -- `~/.config/leankohaku/default-account.txt`. Returns `{ name: null }`
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
      let eoaNames ← LeanKohaku.Wallet.EoaStore.list
      let mut entries : Array Json := #[]
      for name in eoaNames do
        match ← LeanKohaku.Wallet.EoaStore.load name with
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
      let tpmNames ← listSepoliaKeys
      let stateDir : System.FilePath := ".leankohaku/keystore/tpm2"
      for name in tpmNames do
        let addrFile := stateDir / name / "r1-account-address.txt"
        let address ←
          if ← addrFile.pathExists then
            let raw ← IO.FS.readFile addrFile
            pure raw.trimAscii.toString
          else pure ""
        entries := entries.push <| .obj #[
          ("type",    .str "tpm"),
          ("name",    .str name),
          ("address", .str address)
        ]
      -- SPHINCS- hybrid smart accounts. Each slot's identity is its
      -- CREATE2 smart-account address; we surface it as `address` so
      -- the TUI / CLI can treat it uniformly with EOA / TPM rows. When
      -- the counterfactual hasn't been computed yet the field stays
      -- empty — the SphincsAccountsHub detail view exposes "Compute
      -- counterfactual address" to populate it.
      try
        let sphincsNames ← LeanKohaku.Wallet.SphincsHybridStore.listSlotNames
        for name in sphincsNames do
          match ← LeanKohaku.Wallet.SphincsHybridStore.readRecord name with
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

end LeanKohaku.Daemon.Server.AccountRpc
