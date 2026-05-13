import LeanKohaku.Basic
import LeanKohaku.Cli.Commands
import LeanKohaku.Cli.DaemonClient
import LeanKohaku.Cli.NetworkConfig
import LeanKohaku.Cli.Passphrase
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.Encoding.Json
import LeanKohaku.Invariants.EthAmount
import LeanKohaku.Wallet.PpSecretStore
import LeanKohaku.Swap.Tokens
import LeanKohaku.Swap.UniV3
import LeanKohaku.Invariants.Swap

/-!
# CLI runtime

Thin command executor. Wallet, keystore, signing, and chain operations are
forwarded to the daemon over JSON-RPC.
-/

namespace LeanKohaku.Cli

open LeanKohaku.Cli.Commands

/-- Locate the `kohakuspawn` script and exec it with the given args. Search
    order:
      1. `$LEANKOHAKU_KOHAKUSPAWN`        — explicit override (dev / packagers)
      2. `$KOHAKU_HOME/bin/kohakuspawn`   — the self-installed copy
      3. `$HOME/.kohaku/bin/kohakuspawn`  — default install location
      4. `<appDir>/../../script/kohakuspawn` — repo-dev layout (Lean binary
                                            sits at <repo>/.lake/build/bin/)
      5. PATH lookup `kohakuspawn`         — last resort
    Returns the script's exit code so `kohaku install` surfaces install
    failures cleanly. -/
def runKohakuspawn (extraArgs : Array String) : IO UInt32 := do
  let envOverride? ← IO.getEnv "LEANKOHAKU_KOHAKUSPAWN"
  let kohakuHome? ← IO.getEnv "KOHAKU_HOME"
  let home? ← IO.getEnv "HOME"
  let appDir ← IO.appDir
  let repoScript : System.FilePath := appDir / ".." / ".." / "script" / "kohakuspawn"
  let candidates : Array System.FilePath := #[]
  let candidates := match envOverride? with
    | some p => candidates.push (System.FilePath.mk p)
    | none => candidates
  let candidates := match kohakuHome? with
    | some h => candidates.push (System.FilePath.mk h / "bin" / "kohakuspawn")
    | none => candidates
  let candidates := match home? with
    | some h => candidates.push (System.FilePath.mk h / ".kohaku" / "bin" / "kohakuspawn")
    | none => candidates
  let candidates := candidates.push repoScript
  let mut resolved? : Option System.FilePath := none
  for c in candidates do
    if (← c.pathExists) then
      resolved? := some c
      break
  let cmdSpec : IO.Process.SpawnArgs ←
    match resolved? with
    | some path =>
        pure { cmd := path.toString,
               args := extraArgs,
               stdin := .inherit, stdout := .inherit, stderr := .inherit }
    | none =>
        pure { cmd := "kohakuspawn",
               args := extraArgs,
               stdin := .inherit, stdout := .inherit, stderr := .inherit }
  try
    let child ← IO.Process.spawn cmdSpec
    let code ← child.wait
    pure (UInt32.ofNat code.toNat)
  catch e =>
    IO.eprintln s!"failed to launch kohakuspawn: {e.toString}"
    IO.eprintln ""
    IO.eprintln "Looked for it in:"
    IO.eprintln s!"  $LEANKOHAKU_KOHAKUSPAWN             ({(envOverride?.getD "<unset>")})"
    IO.eprintln s!"  $KOHAKU_HOME/bin/kohakuspawn       ({(kohakuHome?.getD "<unset>")})"
    IO.eprintln s!"  $HOME/.kohaku/bin/kohakuspawn      ({(home?.getD "<unset>")})"
    IO.eprintln s!"  {repoScript}"
    IO.eprintln "  kohakuspawn (PATH)"
    IO.eprintln ""
    IO.eprintln "First-time install? Run `./script/kohakuspawn` from the repo root."
    pure 2

/-- Thin wrapper around the daemon's `daemon.preflight` RPC. The policy
    check + plan summary live daemon-side per CLAUDE.md; the CLI just
    formats the response. -/
def printPreflight (action : Action) : IO UInt32 := do
  let params : LeanKohaku.Encoding.Json.Json :=
    match action with
    | .balance address =>
        .obj #[("method", .str "balance"), ("address", .str address)]
    | .send to amountWei =>
        .obj #[
          ("method", .str "send"),
          ("to", .str to),
          ("amountWei", .num (Int.ofNat amountWei))
        ]
  match ← DaemonClient.call "daemon.preflight" params with
  | .error err =>
      IO.eprintln s!"preflight: daemon error {err.code}: {err.message}"
      return 2
  | .ok r =>
      let okBool := (LeanKohaku.Encoding.Json.getField "ok" r
        >>= LeanKohaku.Encoding.Json.asBool).getD false
      let summary := (LeanKohaku.Encoding.Json.getField "summary" r
        >>= LeanKohaku.Encoding.Json.asString).getD ""
      let plan := (LeanKohaku.Encoding.Json.getField "plan" r
        >>= LeanKohaku.Encoding.Json.asString).getD ""
      if okBool then
        IO.println summary
        IO.println "network: local-daemon daemon-control loopback"
        IO.println s!"daemon-plan: {plan}"
        IO.println "preflight only; use daemon-backed wallet commands for execution"
        return 1
      else
        IO.eprintln summary
        return 2

def runR1WalletDeploy (keyName chain : String) : IO UInt32 := do
  DaemonClient.printTextResult "tpm.deploy"
    (.obj #[("name", .str keyName), ("chain", .str chain)])

def runR1WalletCreate (keyName : String) : IO UInt32 := do
  IO.eprintln s!"Choose a PIN for the new TPM2 key (min {LeanKohaku.Keystore.Tpm2Runtime.minPinLength} chars).\nThe PIN will be bound to the key as the TPM auth value and required for every signature."
  match ← LeanKohaku.Cli.Pin.readConfirmed LeanKohaku.Keystore.Tpm2Runtime.minPinLength with
  | .error err =>
      IO.eprintln s!"error: {err}"
      return 2
  | .ok pin =>
      let createCode ← DaemonClient.printTextResult "tpm.create"
        (.obj #[("name", .str keyName), ("pin", .str pin)])
      if createCode ≠ 0 then return createCode
      IO.print s!"\nDeploy R1 account for '{keyName}' on Sepolia now? [Y/n] "
      (← IO.getStdout).flush
      let answer := (← (← IO.getStdin).getLine).trim.toLower
      if answer = "" || answer = "y" || answer = "yes" then
        IO.println "→ deploying…"
        runR1WalletDeploy keyName "sepolia"
      else
        IO.println s!"Skipped. Deploy later with: kohaku wallet deploy r1 {keyName}"
        pure 0

def runSepoliaWalletList : IO UInt32 := do
  DaemonClient.printTextResult "tpm.listSepolia"

/-! ## Default-account persistence

The daemon owns the file (`account.getDefault` / `account.setDefault`); the
CLI is a thin forwarder per CLAUDE.md. These wrappers preserve the original
function names so call sites don't have to change.

When the daemon is unreachable (e.g. completion firing during install) the
read silently returns `none` so users don't see daemon errors in their
prompt; the write surfaces the daemon error since callers are explicitly
asking to persist state. -/

def readDefaultAccount : IO (Option String) := do
  match ← DaemonClient.call "account.getDefault" with
  | .ok r =>
      match LeanKohaku.Encoding.Json.getField "name" r with
      | some (LeanKohaku.Encoding.Json.Json.str s) =>
          if s.isEmpty then pure none else pure (some s)
      | _ => pure none
  | .error _ => pure none

def writeDefaultAccount (wallet : String) : IO Unit := do
  let _ ← DaemonClient.call "account.setDefault"
    (.obj #[("name", .str wallet)])
  pure ()

inductive SlotType where
  | eoa
  | tpm
  deriving Repr, DecidableEq

/-! Thin wrappers around the daemon's unified `account.list` RPC.

These three functions used to each call `eoa.list` + `tpm.listSepoliaAddresses`
and concat the result. The daemon now ships a single `account.list` that
returns `{ accounts: [{type, name, address, indices?}] }`; the CLI is just
a pretty-printer per `CLAUDE.md`. -/

private def fetchAccountList : IO (Array LeanKohaku.Encoding.Json.Json) := do
  match ← DaemonClient.call "account.list" with
  | .error _ => pure #[]
  | .ok r =>
      pure <| (LeanKohaku.Encoding.Json.getField "accounts" r
        >>= LeanKohaku.Encoding.Json.asArray).getD #[]

/-- Query daemon to figure out whether `name` is an EOA slot or a TPM/R1 slot. -/
def resolveSlotType (name : String) : IO (Option SlotType) := do
  for e in (← fetchAccountList) do
    let entryName := (LeanKohaku.Encoding.Json.getField "name" e
                      >>= LeanKohaku.Encoding.Json.asString).getD ""
    if entryName = name then
      let typ := (LeanKohaku.Encoding.Json.getField "type" e
                  >>= LeanKohaku.Encoding.Json.asString).getD ""
      match typ with
      | "eoa" => return some .eoa
      | "tpm" => return some .tpm
      | _ => return none
  pure none

/-- Print one wallet name per line; EOA first, then TPM. Used by completion. -/
def printAccountListNames : IO UInt32 := do
  for e in (← fetchAccountList) do
    let n := (LeanKohaku.Encoding.Json.getField "name" e
              >>= LeanKohaku.Encoding.Json.asString).getD ""
    if !n.isEmpty then IO.println n
  pure 0

/-- Print `<type>\t<name>` per line — type is `eoa` or `tpm`. Used by
    completion so it can render the `<wallet>/<index>` subaccount form
    only for EOA wallets (TPM/R1 keys have no derivation indices). -/
def printAccountListTypedNames : IO UInt32 := do
  for e in (← fetchAccountList) do
    let typ := (LeanKohaku.Encoding.Json.getField "type" e
                >>= LeanKohaku.Encoding.Json.asString).getD ""
    let n := (LeanKohaku.Encoding.Json.getField "name" e
              >>= LeanKohaku.Encoding.Json.asString).getD ""
    if !n.isEmpty && !typ.isEmpty then IO.println s!"{typ}\t{n}"
  pure 0

/-- Print one sub-account index per line for the given EOA wallet. Used by
    bash/zsh completion: when `--account` follows a command where it selects
    a sub-account, Tab cycles through these indices. Falls back to
    `readDefaultAccount` when no wallet name is given. Silent on every error
    so completion never pollutes stderr. -/
def printAccountListIndices (wallet? : Option String) : IO UInt32 := do
  let resolved? : Option String ← match wallet? with
    | some w => pure (some w)
    | none => readDefaultAccount
  match resolved? with
  | none => pure 0
  | some w =>
      let slotName := (w.splitOn "/").headD w
      for e in (← fetchAccountList) do
        let entryName := (LeanKohaku.Encoding.Json.getField "name" e
                          >>= LeanKohaku.Encoding.Json.asString).getD ""
        if entryName = slotName then
          let indices := (LeanKohaku.Encoding.Json.getField "indices" e
                          >>= LeanKohaku.Encoding.Json.asArray).getD #[]
          for ie in indices do
            match LeanKohaku.Encoding.Json.asNat ie with
            | some n => IO.println (toString n)
            | none => pure ()
      pure 0

/-- Print one `wallet/index` per line, optionally followed by `\t<address>`.
    With no filter, walks every EOA wallet from `eoa.list`. Silent on every
    daemon error so completion never pollutes stderr (return 0). -/
def printAccountListWalletIndices (withAddresses : Bool) (filter? : Option String) :
    IO UInt32 := do
  let wallets : Array String ← match filter? with
    | some w => pure #[(w.splitOn "/").headD w]
    | none =>
        match ← DaemonClient.call "eoa.list" with
        | .error _ => pure #[]
        | .ok r =>
            let arr := (LeanKohaku.Encoding.Json.asArray r).getD #[]
            pure (arr.filterMap fun e =>
              LeanKohaku.Encoding.Json.getField "name" e
                >>= LeanKohaku.Encoding.Json.asString)
  for w in wallets do
    if w.isEmpty then continue
    match ← DaemonClient.call "eoa.account.list"
          (.obj #[("name", .str w)]) with
    | .error _ => pure ()
    | .ok r =>
        let entries := (LeanKohaku.Encoding.Json.getField "accounts" r
                        >>= LeanKohaku.Encoding.Json.asArray).getD #[]
        for e in entries do
          match LeanKohaku.Encoding.Json.getField "index" e
                >>= LeanKohaku.Encoding.Json.asNat with
          | none => pure ()
          | some n =>
              if withAddresses then
                let addr := (LeanKohaku.Encoding.Json.getField "address" e
                              >>= LeanKohaku.Encoding.Json.asString).getD ""
                IO.println s!"{w}/{n}\t{addr}"
              else
                IO.println s!"{w}/{n}"
  pure 0

private def hexWeiToNat (s : String) : Option Nat :=
  let raw := strip0x s
  raw.toList.foldl
    (init := some 0)
    (fun acc c =>
      match acc, hexDigit? c with
      | some n, some d => some (n * 16 + d)
      | _, _ => none)

private def formatGwei (n : Nat) : String :=
  let whole := n / 1000000000
  let frac := n % 1000000000
  if frac = 0 then s!"{whole} gwei"
  else
    let s := toString frac
    let pad := String.mk (List.replicate (9 - s.length) '0')
    let trimmed := (pad ++ s).dropRightWhile (· = '0')
    s!"{whole}.{trimmed} gwei"

private def formatEth (n : Nat) : String :=
  let whole := n / 1000000000000000000
  let frac := n % 1000000000000000000
  if frac = 0 then s!"{whole} ETH"
  else
    let s := toString frac
    let pad := String.mk (List.replicate (18 - s.length) '0')
    let trimmed := (pad ++ s).dropRightWhile (· = '0')
    s!"{whole}.{trimmed} ETH"

private def printFeeField (method field : String) : IO UInt32 := do
  match ← DaemonClient.call method with
  | .ok result =>
      match LeanKohaku.Encoding.Json.getField field result >>= LeanKohaku.Encoding.Json.asString with
      | some hex =>
          match hexWeiToNat hex with
          | some wei =>
              IO.println s!"{formatGwei wei}  ({wei} wei, {hex})"
              pure 0
          | none =>
              IO.println (LeanKohaku.Encoding.Json.pretty result)
              pure 0
      | none =>
          IO.println (LeanKohaku.Encoding.Json.pretty result)
          pure 0
  | .error err =>
      IO.eprintln s!"daemon error {err.code}: {err.message}"
      pure 2

private def truncateStr (max : Nat) (s : String) : String :=
  if s.length ≤ max then s
  else String.ofList (s.toList.take max) ++ "…"

private def hostOf (url : String) : String :=
  let stripScheme : String :=
    match url.splitOn "://" with
    | _ :: rest :: _ => rest
    | _ => url
  match stripScheme.splitOn "/" with
  | h :: _ => h
  | _ => stripScheme

private def prettyHexValue (hex : String) : Option String := do
  let raw := strip0x hex
  if raw.isEmpty then none
  else
    let n ← hexWeiToNat hex
    some s!"{formatEth n} ({n} wei)"

private def renderJsonField (j : LeanKohaku.Encoding.Json.Json) : String :=
  truncateStr 220 (LeanKohaku.Encoding.Json.compact j)

open LeanKohaku.Encoding.Json in
private def formatNetEvent (rawLine : String) : String :=
  let line := rawLine.trimRight
  match parse line with
  | .error _ => line
  | .ok json =>
      let getStr (k : String) : Option String := getField k json >>= asString
      let getMs : Option Nat :=
        match getField "ms" json with
        | some (.num n) => some n.toNat
        | _ => none
      let kind := (getStr "kind").getD "?"
      let method := (getStr "method").getD "?"
      let arrow :=
        match kind with
        | "request" => "→"
        | "response" => "←"
        | "denied" => "⛔"
        | _ => "✗"
      let msPart := match getMs with | some n => s!"  +{n}ms" | none => ""
      match kind with
      | "request" =>
          let host := (getStr "url").map hostOf |>.getD "?"
          let params :=
            match getField "params" json with
            | some j => renderJsonField j
            | none => ""
          s!"{arrow} {method}  host={host}  params={params}"
      | "response" =>
          let resultPretty :=
            match getField "result" json with
            | some (.str hex) =>
                match prettyHexValue hex with
                | some pretty =>
                    if method = "eth_getBalance" || method = "eth_gasPrice" || method = "eth_maxPriorityFeePerGas"
                    then s!"{hex}  ({pretty})"
                    else hex
                | none => hex
            | some j => renderJsonField j
            | none => ""
          s!"{arrow} {method}{msPart}  result={resultPretty}"
      | "rpc-error" =>
          let err :=
            match getField "error" json with
            | some j => renderJsonField j
            | none => "?"
          s!"{arrow} {method}{msPart}  rpc-error  {err}"
      | "denied" =>
          let backend := (getStr "backend").getD "?"
          let transport := (getStr "transport").getD "?"
          s!"{arrow} {method}  DENIED  backend={backend} transport={transport}"
      | "exception" | "parse-error" | "malformed" =>
          let detail := (getStr "error").getD ""
          if detail.isEmpty then s!"{arrow} {method}{msPart}  {kind}"
          else s!"{arrow} {method}{msPart}  {kind}: {truncateStr 220 detail}"
      | _ => line

partial def streamNetLog (h : IO.FS.Handle) : IO Unit := do
  let line ← h.getLine
  if line.isEmpty then pure ()
  else
    IO.println (formatNetEvent line)
    streamNetLog h

def runDaemonForeground : IO UInt32 := do
  -- Resolve in the same order as DaemonClient.daemonBin:
  -- 1. explicit env override
  -- 2. sibling of the running `leankohaku` binary (the canonical install layout)
  -- 3. bare name, letting $PATH resolve (last-resort fallback)
  -- Why: a stale `leankohaku-daemon` on $PATH from a sibling checkout would
  -- otherwise be picked over a freshly-built one in the same .lake/build/bin/.
  let bin ←
    match ← IO.getEnv "LEANKOHAKU_DAEMON_BIN" with
    | some path => pure path
    | none =>
        let candidate := (← IO.appDir) / "leankohaku-daemon"
        if ← candidate.pathExists then
          pure candidate.toString
        else
          pure "leankohaku-daemon"
  let child ← IO.Process.spawn
    { cmd := bin,
      stdin := .inherit,
      stdout := .inherit,
      stderr := .inherit }
  child.wait

private def withOptionalPath (fields : Array (String × LeanKohaku.Encoding.Json.Json))
    (path? : Option String) : LeanKohaku.Encoding.Json.Json :=
  match path? with
  | none => .obj fields
  | some path => .obj (fields.push ("path", .str path))

private def withOptionalDerivationPath (fields : Array (String × LeanKohaku.Encoding.Json.Json))
    (path? : Option String) : LeanKohaku.Encoding.Json.Json :=
  match path? with
  | none => .obj fields
  | some path => .obj (fields.push ("derivationPath", .str path))

private def eoaCreate (name : String) (path? : Option String) : IO UInt32 := do
  let passphrase ← Passphrase.read
  DaemonClient.printCall "eoa.create"
    (withOptionalDerivationPath #[
      ("name", .str name),
      ("passphrase", .str passphrase)
    ] path?)

private def eoaImport (name mnemonic : String) (path? : Option String) : IO UInt32 := do
  let passphrase ← Passphrase.read
  DaemonClient.printCall "eoa.import"
    (withOptionalDerivationPath #[
      ("name", .str name),
      ("mnemonic", .str mnemonic),
      ("passphrase", .str passphrase)
    ] path?)

private def eoaUnlock (name : String) : IO UInt32 := do
  let passphrase ← Passphrase.read
  DaemonClient.printCall "eoa.unlock"
    (.obj #[("name", .str name), ("passphrase", .str passphrase)])

private def eoaDelete (name : String) : IO UInt32 := do
  let passphrase ← Passphrase.read "Passphrase for delete: "
  DaemonClient.printCall "eoa.delete"
    (.obj #[("name", .str name), ("passphrase", .str passphrase)])

/-- Append `("account", n)` to a fields array if a `--account` index was
    provided on the CLI. Errors out (returns `none`) if the index doesn't parse
    as a Nat. -/
private def withOptionalAccount (fields : Array (String × LeanKohaku.Encoding.Json.Json))
    (accountIdx? : Option String) : Except String (Array (String × LeanKohaku.Encoding.Json.Json)) :=
  match accountIdx? with
  | none => .ok fields
  | some s =>
      match s.toNat? with
      | some n => .ok (fields.push ("account", .num (Int.ofNat n)))
      | none => .error s!"invalid --account value (expected non-negative integer): {s}"

/-- Resolve a `--account` raw value against a positional wallet `name`.
    Accepts `<idx>` (returns `some idx`), `<wallet>/<idx>` (validates wallet
    matches `name`, returns `some idx`), or `<wallet>` (matching, returns
    `none` for index). Errors on a wallet mismatch — refuse to silently use
    the positional and drop the user's flag-supplied wallet, since that's a
    UX trap that would route a signing op to the wrong wallet.
    Why: keeps the SAFE/UNSAFE-style invariant that a flag-supplied wallet
    is never silently overridden by a positional. -/
private def resolveAccountForName (name : String) (accountIdx? : Option String) :
    Except String (Option String) :=
  match accountIdx? with
  | none => .ok none
  | some s =>
      let (w?, idx?) := splitAccountFlag s
      match w? with
      | none => .ok idx?
      | some w =>
          if w = name then .ok idx?
          else .error s!"--account wallet \"{w}\" doesn't match positional wallet \"{name}\""

-- Why: when the daemon returns -32012 EOA slot is locked, prompt the user
-- for the slot's passphrase, unlock, and retry the original call once. This
-- replaces the legacy UX where the user had to run `wallet unlock` first.
private def callWithAutoUnlock (slotName method : String)
    (params : LeanKohaku.Encoding.Json.Json) :
    IO (Except DaemonClient.RpcError LeanKohaku.Encoding.Json.Json) := do
  match ← DaemonClient.call method params with
  | .ok r => pure (.ok r)
  | .error err =>
      if err.code = -32012 then
        IO.println s!"🔒 wallet '{slotName}' is locked"
        let passphrase ← Passphrase.read s!"Passphrase for {slotName}: "
        match ← DaemonClient.call "eoa.unlock"
            (.obj #[("name", .str slotName), ("passphrase", .str passphrase)]) with
        | .error e =>
            pure (.error { code := e.code, message := s!"unlock failed: {e.message}" })
        | .ok _ =>
            IO.println s!"✓ unlocked {slotName}; retrying"
            DaemonClient.call method params
      else
        pure (.error err)

-- Why: same auto-unlock retry as callWithAutoUnlock, but pretty-prints the
-- daemon result instead of returning it. Used by sign-* commands.
private def printCallWithAutoUnlock (slotName method : String)
    (params : LeanKohaku.Encoding.Json.Json) : IO UInt32 := do
  match ← callWithAutoUnlock slotName method params with
  | .ok r => IO.println (LeanKohaku.Encoding.Json.pretty r); pure 0
  | .error err =>
      IO.eprintln s!"daemon error {err.code}: {err.message}"
      pure 2

private def eoaSignDigestCall (name digest : String) (accountIdx? : Option String) : IO UInt32 := do
  match resolveAccountForName name accountIdx? with
  | .error err => IO.eprintln err; pure 2
  | .ok idx? =>
    match withOptionalAccount #[("name", .str name), ("digest", .str digest)] idx? with
    | .error err => IO.eprintln err; pure 2
    | .ok fields => printCallWithAutoUnlock name "eoa.signDigest" (.obj fields)

private def eoaSignMessage (name message : String) (path? : Option String)
    (accountIdx? : Option String) : IO UInt32 := do
  match resolveAccountForName name accountIdx? with
  | .error err => IO.eprintln err; pure 2
  | .ok idx? =>
    let base := withOptionalPath #[("name", .str name), ("message", .str message)] path?
    let fields :=
      match base with
      | .obj fs => fs
      | _ => #[]
    match withOptionalAccount fields idx? with
    | .error err => IO.eprintln err; pure 2
    | .ok fs => printCallWithAutoUnlock name "eoa.signMessage" (.obj fs)

private def eoaSignTx (name txJson : String) (path? : Option String)
    (accountIdx? : Option String) : IO UInt32 := do
  match LeanKohaku.Encoding.Json.parse txJson with
  | .error err =>
      IO.eprintln s!"invalid transaction JSON: {err}"
      return 2
  | .ok tx =>
      match resolveAccountForName name accountIdx? with
      | .error err => IO.eprintln err; pure 2
      | .ok idx? =>
        let base := withOptionalPath #[("name", .str name), ("tx", tx)] path?
        let fields := match base with | .obj fs => fs | _ => #[]
        match withOptionalAccount fields idx? with
        | .error err => IO.eprintln err; pure 2
        | .ok fs => printCallWithAutoUnlock name "eoa.signTx" (.obj fs)

private def eoaSignTypedData (name typedDataJson : String) (path? : Option String)
    (accountIdx? : Option String) : IO UInt32 := do
  match LeanKohaku.Encoding.Json.parse typedDataJson with
  | .error err =>
      IO.eprintln s!"invalid typed-data JSON: {err}"
      return 2
  | .ok typedData =>
      match resolveAccountForName name accountIdx? with
      | .error err => IO.eprintln err; pure 2
      | .ok idx? =>
        let base := withOptionalPath #[("name", .str name), ("typedData", typedData)] path?
        let fields := match base with | .obj fs => fs | _ => #[]
        match withOptionalAccount fields idx? with
        | .error err => IO.eprintln err; pure 2
        | .ok fs => printCallWithAutoUnlock name "eoa.signTypedData" (.obj fs)

/-- Resolve user input that should be either an explicit 0x address or an ENS
    name. On a successful name lookup, prints a `Resolved <name> -> 0x...` line
    so the user sees the address before any send is forwarded to the daemon.

    Why: keeps `validAddressString` semantics intact for explicit addresses
    while letting any address-taking CLI command accept an ENS name. -/
private def resolveAddressOrName (input : String) : IO (Except String String) := do
  if validAddressString input then
    pure (.ok input)
  else if input.contains '.' then
    match ← DaemonClient.call "chain.resolveName"
        (.obj #[("name", .str input)]) with
    | .error err =>
        pure (.error s!"ENS resolution failed: {err.message}")
    | .ok result =>
        match LeanKohaku.Encoding.Json.getField "address" result
              >>= LeanKohaku.Encoding.Json.asString with
        | none => pure (.error s!"ENS resolution returned no address for {input}")
        | some addr =>
            IO.println s!"Resolved {input} → {addr}"
            pure (.ok addr)
  else
    pure (.error s!"not a valid address or ENS name: {input}")

-- Why: when the daemon returns -32012 EOA slot is locked, prompt the user
-- for the slot's passphrase, unlock, and retry the original call once. This
-- replaces the legacy UX where the user had to run `wallet unlock` first.
private def dispatchEoaSend (name to : String) (valueNat : Nat)
    (data? : Option String) (accountIdx? : Option String := none) : IO UInt32 := do
  match ← resolveAddressOrName to with
  | .error err =>
      IO.eprintln s!"invalid eoa send recipient: {err}"
      return 2
  | .ok to =>
  if !validAddressString to then
    IO.eprintln s!"invalid eoa send recipient: {to}"
    return 2
  else
    let fields := #[
      ("name", .str name),
      ("to", .str to),
      ("value", .num (Int.ofNat valueNat))
    ]
    let fields :=
      match data? with
      | none => fields
      | some data => fields.push ("data", .str data)
    match withOptionalAccount fields accountIdx? with
    | .error err => IO.eprintln err; pure 2
    | .ok fields =>
    let params : LeanKohaku.Encoding.Json.Json := .obj fields
    match ← callWithAutoUnlock name "eoa.send" params with
    | .error err =>
        IO.eprintln s!"daemon error {err.code}: {err.message}"
        pure 2
    | .ok result =>
        let getStr (k : String) : String :=
          (LeanKohaku.Encoding.Json.getField k result >>= LeanKohaku.Encoding.Json.asString).getD ""
        let txHash := getStr "txHash"
        let status := getStr "status"
        let blockHex := getStr "blockNumber"
        let gasUsedHex := getStr "gasUsed"
        let effPriceHex := getStr "effectiveGasPrice"
        let block := (hexWeiToNat blockHex).getD 0
        let gasUsed := (hexWeiToNat gasUsedHex).getD 0
        let effPrice := (hexWeiToNat effPriceHex).getD 0
        let fromAddr :=
          (LeanKohaku.Encoding.Json.getField "from" result >>= LeanKohaku.Encoding.Json.asString).getD ""
        match status with
        | "success" =>
            IO.println "✓ tx mined"
            IO.println s!"  hash:    {txHash}"
            IO.println s!"  block:   {block}"
            if !fromAddr.isEmpty then IO.println s!"  from:    {fromAddr}"
            IO.println s!"  to:      {to}"
            IO.println s!"  value:   {formatEth valueNat}"
            IO.println s!"  gas:     {gasUsed}  (effectivePrice {formatGwei effPrice})"
            if !fromAddr.isEmpty then
              match ← DaemonClient.call "chain.balance" (.obj #[("address", .str fromAddr)]) with
              | .ok r =>
                  let hex := (LeanKohaku.Encoding.Json.getField "balance" r
                              >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
                  let wei := (hexWeiToNat hex).getD 0
                  IO.println s!"  remaining: {formatEth wei}  ({name})"
              | .error _ => pure ()
            IO.println s!"  https://sepolia.etherscan.io/tx/{txHash}"
            pure 0
        | "revert" =>
            IO.println "✗ tx reverted"
            IO.println s!"  hash:    {txHash}"
            IO.println s!"  block:   {block}"
            IO.println s!"  to:      {to}"
            IO.println s!"  value:   {formatEth valueNat}"
            IO.println s!"  gas:     {gasUsed}  (effectivePrice {formatGwei effPrice})"
            IO.println s!"  https://sepolia.etherscan.io/tx/{txHash}"
            IO.println "  revert reason: not available (no decoder for receipt logs yet)"
            pure 1
        | "pending" =>
            let errMsg :=
              (LeanKohaku.Encoding.Json.getField "error" result >>= LeanKohaku.Encoding.Json.asString).getD ""
            IO.println s!"⚠ still pending; {errMsg}"
            IO.println s!"  hash: {txHash}"
            IO.println s!"  https://sepolia.etherscan.io/tx/{txHash}"
            pure 1
        | _ =>
            -- Unknown / missing status — fall back to raw pretty-print so
            -- nothing is silently dropped.
            IO.println (LeanKohaku.Encoding.Json.pretty result)
            pure 0

/-! ## Pretty-printers for `wallet show` and `--all` aggregates -/

-- Why: rendering Unix epoch seconds as ISO-8601 without Mathlib. Standard
-- "civil from days" algorithm (Howard Hinnant, public domain).
private def epochToIsoDate (epoch : Nat) : String :=
  -- days since 1970-01-01
  let days : Int := Int.ofNat (epoch / 86400)
  -- shift to internal epoch 0000-03-01
  let z : Int := days + 719468
  let era : Int := (if z ≥ 0 then z else z - 146096) / 146097
  let doe : Int := z - era * 146097                                 -- [0, 146096]
  let yoe : Int := (doe - doe/1460 + doe/36524 - doe/146096) / 365 -- [0, 399]
  let y0 : Int := yoe + era * 400
  let doy : Int := doe - (365*yoe + yoe/4 - yoe/100)               -- [0, 365]
  let mp  : Int := (5*doy + 2) / 153                                -- [0, 11]
  let d   : Int := doy - (153*mp + 2)/5 + 1                         -- [1, 31]
  let m   : Int := if mp < 10 then mp + 3 else mp - 9              -- [1, 12]
  let y   : Int := if m ≤ 2 then y0 + 1 else y0
  let pad2 (n : Int) : String :=
    let s := toString n
    if s.length < 2 then "0" ++ s else s
  s!"{y}-{pad2 m}-{pad2 d}"

private def renderEoaShow (record : LeanKohaku.Encoding.Json.Json) (name : String) : IO Unit := do
  let getStr (k : String) : String :=
    (LeanKohaku.Encoding.Json.getField k record >>= LeanKohaku.Encoding.Json.asString).getD ""
  let addr := getStr "address"
  let path := getStr "derivationPath"
  let locked :=
    match LeanKohaku.Encoding.Json.getField "locked" record with
    | some (.bool b) => b
    | _ => true
  let createdAt :=
    (LeanKohaku.Encoding.Json.getField "createdAt" record
      >>= LeanKohaku.Encoding.Json.asNat).getD 0
  -- Why: tiny values (e.g. monotonic-ish counters) shouldn't be rendered as
  -- 1970 dates. Threshold ~ year 2001 in unix seconds.
  let createdLine :=
    if createdAt > 1000000000 then
      s!"{epochToIsoDate createdAt}  (unix {createdAt} — value as stored)"
    else
      s!"{createdAt} (raw; value as stored)"
  IO.println s!"Wallet: {name}"
  IO.println s!"  type:            eoa"
  IO.println s!"  primary address: {addr}"
  IO.println s!"  derivation:      {path}"
  IO.println s!"  locked:          {if locked then "yes" else "no"}"
  IO.println s!"  created:         {createdLine}"
  let subs ←
    match ← DaemonClient.call "eoa.account.list" (.obj #[("name", .str name)]) with
    | .ok r =>
        pure ((LeanKohaku.Encoding.Json.getField "accounts" r
                >>= LeanKohaku.Encoding.Json.asArray).getD #[])
        -- Why: include the primary account (#0) too; we filter it before printing.
    | .error _ => pure #[]
  let nonPrimary := subs.filter fun a =>
    ((LeanKohaku.Encoding.Json.getField "index" a
      >>= LeanKohaku.Encoding.Json.asNat).getD 0) ≠ 0
  IO.println s!"  sub-accounts:    {nonPrimary.size}"
  for a in nonPrimary do
    let idx := (LeanKohaku.Encoding.Json.getField "index" a
                  >>= LeanKohaku.Encoding.Json.asNat).getD 0
    let aAddr := (LeanKohaku.Encoding.Json.getField "address" a
                  >>= LeanKohaku.Encoding.Json.asString).getD ""
    let aPath := (LeanKohaku.Encoding.Json.getField "path" a
                  >>= LeanKohaku.Encoding.Json.asString).getD ""
    IO.println s!"    └ #{idx}  {aAddr}  {aPath}"

private def renderTpmShow (name addr : String) : IO Unit := do
  let keyDir : System.FilePath := s!".leankohaku/keystore/tpm2/{name}"
  let manifestPath := keyDir / "manifest.txt"
  let publicPath := keyDir / "public.pem"
  let addrLine := if addr.isEmpty then "(no address; deploy first)" else addr
  IO.println s!"Wallet: {name}"
  IO.println s!"  type:            r1 (TPM2 P-256)"
  IO.println s!"  smart account:   {addrLine}"
  -- Why: stat-verify each path so the user sees `(missing)` when the on-disk
  -- blob is gone, instead of being misled by a hopeful string.
  let dirExists ← keyDir.pathExists
  if !dirExists then
    IO.println s!"  key directory:   {keyDir} (MISSING — TPM record not on disk)"
  else
    let manExists ← manifestPath.pathExists
    let pubExists ← publicPath.pathExists
    let tag (b : Bool) : String := if b then "" else " (missing)"
    IO.println s!"  key directory:   {keyDir}"
    IO.println s!"  manifest:        {manifestPath}{tag manExists}"
    IO.println s!"  public key:      {publicPath}{tag pubExists}"
  IO.println "  signing requires the TPM-bound PIN (checked by the TPM)"

private def prettyEoaShow (name : String) : IO UInt32 := do
  match ← DaemonClient.call "eoa.show" (.obj #[("name", .str name)]) with
  | .error err =>
      IO.eprintln s!"daemon error {err.code}: {err.message}"
      pure 2
  | .ok r =>
      renderEoaShow r name
      pure 0

private def prettyTpmShow (name : String) : IO UInt32 := do
  match ← DaemonClient.call "tpm.listSepoliaAddresses" with
  | .error err =>
      IO.eprintln s!"daemon error {err.code}: {err.message}"
      pure 2
  | .ok r =>
      let entries := (LeanKohaku.Encoding.Json.asArray r).getD #[]
      match entries.find? (fun e =>
        ((LeanKohaku.Encoding.Json.getField "name" e
          >>= LeanKohaku.Encoding.Json.asString).getD "") = name) with
      | none =>
          IO.eprintln s!"error: TPM record for '{name}' not found"
          pure 2
      | some e =>
          let addr := (LeanKohaku.Encoding.Json.getField "address" e
                        >>= LeanKohaku.Encoding.Json.asString).getD ""
          renderTpmShow name addr
          pure 0

/-- Per-wallet history rendering used by `wallet history --all`. Layer 1
    journal + optional Layer 2 log scan; no account filter, no indexer leak. -/
private def runWalletHistoryFor (name : String) (scanLogs : Bool)
    (limit? : Option Nat) (chain? : Option String) : IO Unit := do
  let limit := limit?.getD 50
  let renderEntry (e : LeanKohaku.Encoding.Json.Json) : IO Unit := do
    let getStr (k : String) : String :=
      (LeanKohaku.Encoding.Json.getField k e >>= LeanKohaku.Encoding.Json.asString).getD ""
    let getNat (k : String) : Nat :=
      (LeanKohaku.Encoding.Json.getField k e >>= LeanKohaku.Encoding.Json.asNat).getD 0
    let kind := getStr "kind"
    let txHash := getStr "txHash"
    let ts := getNat "timestamp"
    let toAddr := getStr "to"
    let fromA := getStr "from"
    let valueStr := getStr "valueWei"
    let valueWei := valueStr.toNat?.getD 0
    let block := getStr "blockNumber"
    let status := getStr "status"
    let truncH := if txHash.length ≤ 14 then txHash
                  else (txHash.toList.take 10 |> String.mk) ++ "…"
    IO.println s!"  {ts}  [{kind}]  {truncH}  {fromA} → {toAddr}  {formatEth valueWei}  block={block}  status={status}"
  let allEntries ←
    match ← DaemonClient.call "chain.history"
        (.obj #[("name", .str name), ("limit", .num (Int.ofNat limit))]) with
    | .ok r => pure ((LeanKohaku.Encoding.Json.asArray r).getD #[])
    | .error err =>
        IO.eprintln s!"  daemon error {err.code}: {err.message}"
        pure #[]
  IO.println s!"Local journal ({allEntries.size} entries):"
  for e in allEntries do renderEntry e
  if scanLogs then
    IO.println ""
    IO.println "Scanning chain logs (this may take a while)…"
    match ← DaemonClient.call "eoa.show" (.obj #[("name", .str name)]) with
    | .error err => IO.eprintln s!"  eoa.show failed: {err.message}"
    | .ok rec =>
        let addr := (LeanKohaku.Encoding.Json.getField "address" rec
                      >>= LeanKohaku.Encoding.Json.asString).getD ""
        let subs ← match ← DaemonClient.call "eoa.account.list"
              (.obj #[("name", .str name)]) with
          | .ok r =>
              pure ((LeanKohaku.Encoding.Json.getField "accounts" r
                      >>= LeanKohaku.Encoding.Json.asArray).getD #[])
          | .error _ => pure #[]
        let mut addrs : Array LeanKohaku.Encoding.Json.Json :=
          if addr.isEmpty then #[] else #[.str addr]
        for a in subs do
          let aAddr := (LeanKohaku.Encoding.Json.getField "address" a
                        >>= LeanKohaku.Encoding.Json.asString).getD ""
          if !aAddr.isEmpty && aAddr ≠ addr then
            addrs := addrs.push (.str aAddr)
        let baseFields : Array (String × LeanKohaku.Encoding.Json.Json) :=
          #[("addresses", .arr addrs), ("slotName", .str name)]
        let scanFields :=
          match chain? with
          | none => baseFields
          | some c => baseFields.push ("chain", .str c)
        match ← DaemonClient.call "chain.scanTransfers" (.obj scanFields) with
        | .error err => IO.eprintln s!"  chain.scanTransfers failed: {err.message}"
        | .ok r =>
            let events := (LeanKohaku.Encoding.Json.getField "events" r
                            >>= LeanKohaku.Encoding.Json.asArray).getD #[]
            IO.println s!"  on-chain Transfer events: {events.size}"
            for ev in events do
              let txHash := (LeanKohaku.Encoding.Json.getField "transactionHash" ev
                              >>= LeanKohaku.Encoding.Json.asString).getD ""
              let blockN := (LeanKohaku.Encoding.Json.getField "blockNumber" ev
                              >>= LeanKohaku.Encoding.Json.asString).getD ""
              IO.println s!"    {txHash}  block={blockN}"

/-- Per-wallet history rendering for R1 (TPM) wallets. Reads the same
    `<name>.ndjson` journal as EOA wallets. For `--scan-logs`, the address to
    scan is the deployed R1 account address; if undeployed, we skip cleanly. -/
private def runR1WalletHistoryFor (name : String) (scanLogs : Bool)
    (limit? : Option Nat) (chain? : Option String) : IO Unit := do
  let limit := limit?.getD 50
  let renderEntry (e : LeanKohaku.Encoding.Json.Json) : IO Unit := do
    let getStr (k : String) : String :=
      (LeanKohaku.Encoding.Json.getField k e >>= LeanKohaku.Encoding.Json.asString).getD ""
    let getNat (k : String) : Nat :=
      (LeanKohaku.Encoding.Json.getField k e >>= LeanKohaku.Encoding.Json.asNat).getD 0
    let kind := getStr "kind"
    let txHash := getStr "txHash"
    let ts := getNat "timestamp"
    let toAddr := getStr "to"
    let fromA := getStr "from"
    let valueStr := getStr "valueWei"
    let valueWei := valueStr.toNat?.getD 0
    let block := getStr "blockNumber"
    let status := getStr "status"
    let truncH := if txHash.length ≤ 14 then txHash
                  else (txHash.toList.take 10 |> String.mk) ++ "…"
    IO.println s!"  {ts}  [{kind}]  {truncH}  {fromA} → {toAddr}  {formatEth valueWei}  block={block}  status={status}"
  let allEntries ←
    match ← DaemonClient.call "chain.history"
        (.obj #[("name", .str name), ("limit", .num (Int.ofNat limit))]) with
    | .ok r => pure ((LeanKohaku.Encoding.Json.asArray r).getD #[])
    | .error err =>
        IO.eprintln s!"  daemon error {err.code}: {err.message}"
        pure #[]
  IO.println s!"Local journal ({allEntries.size} entries):"
  for e in allEntries do renderEntry e
  if scanLogs then
    IO.println ""
    IO.println "Scanning chain logs (this may take a while)…"
    -- Why: R1 has no `eoa.show`; pull the deployed address from
    -- `tpm.listSepoliaAddresses`. If undeployed, we cannot scan.
    let addr? ← match ← DaemonClient.call "tpm.listSepoliaAddresses" with
      | .error err =>
          IO.eprintln s!"  tpm.listSepoliaAddresses failed: {err.message}"
          pure none
      | .ok r =>
          let entries := (LeanKohaku.Encoding.Json.asArray r).getD #[]
          pure <| entries.findSome? fun e =>
            let n := (LeanKohaku.Encoding.Json.getField "name" e
                      >>= LeanKohaku.Encoding.Json.asString).getD ""
            if n = name then
              LeanKohaku.Encoding.Json.getField "address" e
                >>= LeanKohaku.Encoding.Json.asString
            else none
    match addr? with
    | none =>
        IO.println "  (no deployed address; skipping log scan)"
    | some addr =>
        if addr.isEmpty then
          IO.println "  (R1 account not yet deployed; skipping log scan)"
        else
          let baseFields : Array (String × LeanKohaku.Encoding.Json.Json) :=
            #[("addresses", .arr #[.str addr]), ("slotName", .str name)]
          let scanFields :=
            match chain? with
            | none => baseFields
            | some c => baseFields.push ("chain", .str c)
          match ← DaemonClient.call "chain.scanTransfers" (.obj scanFields) with
          | .error err => IO.eprintln s!"  chain.scanTransfers failed: {err.message}"
          | .ok r =>
              let events := (LeanKohaku.Encoding.Json.getField "events" r
                              >>= LeanKohaku.Encoding.Json.asArray).getD #[]
              IO.println s!"  on-chain Transfer events: {events.size}"
              for ev in events do
                let txHash := (LeanKohaku.Encoding.Json.getField "transactionHash" ev
                                >>= LeanKohaku.Encoding.Json.asString).getD ""
                let blockN := (LeanKohaku.Encoding.Json.getField "blockNumber" ev
                                >>= LeanKohaku.Encoding.Json.asString).getD ""
                IO.println s!"    {txHash}  block={blockN}"

/-- Enumerate every wallet name as `(name, slotType)`. Silent on daemon errors. -/
private def listAllWallets : IO (Array (String × SlotType)) := do
  let mut out : Array (String × SlotType) := #[]
  match ← DaemonClient.call "eoa.list" with
  | .ok r =>
      for e in (LeanKohaku.Encoding.Json.asArray r).getD #[] do
        let n := (LeanKohaku.Encoding.Json.getField "name" e
                  >>= LeanKohaku.Encoding.Json.asString).getD ""
        if !n.isEmpty then out := out.push (n, .eoa)
  | .error _ => pure ()
  match ← DaemonClient.call "tpm.listSepoliaAddresses" with
  | .ok r =>
      for e in (LeanKohaku.Encoding.Json.asArray r).getD #[] do
        let n := (LeanKohaku.Encoding.Json.getField "name" e
                  >>= LeanKohaku.Encoding.Json.asString).getD ""
        if !n.isEmpty then out := out.push (n, .tpm)
  | .error _ => pure ()
  pure out

/-! ## Swap helpers (Slice A/B) -/

/-- Parse a non-negative decimal string with a fixed number of fractional
    decimals into base units. e.g. `parseDecimalToBaseUnits "0.1" 18 = some 100000000000000000`. -/
private def parseDecimalToBaseUnits (s : String) (decimals : Nat) : Option Nat :=
  let parts := s.splitOn "."
  let parseDigits (str : String) : Option Nat :=
    if str.isEmpty then some 0
    else str.toList.foldl
      (init := some 0)
      (fun acc c =>
        match acc with
        | none => none
        | some n =>
            if '0' ≤ c && c ≤ '9' then some (n * 10 + (c.toNat - '0'.toNat))
            else none)
  match parts with
  | [whole] => do
      let w ← parseDigits whole
      some (w * Nat.pow 10 decimals)
  | [whole, frac] => do
      let w ← parseDigits whole
      if frac.length > decimals then none
      else
        let f ← parseDigits frac
        let pad := decimals - frac.length
        some (w * Nat.pow 10 decimals + f * Nat.pow 10 pad)
  | _ => none

/-- Format base units as a decimal string with `decimals` fractional places,
    trimming trailing zeros. -/
private def formatBaseUnits (n decimals : Nat) : String :=
  let scale := Nat.pow 10 decimals
  let whole := n / scale
  let frac := n % scale
  if decimals = 0 || frac = 0 then toString whole
  else
    let str := toString frac
    let pad := String.mk (List.replicate (decimals - str.length) '0')
    let trimmed := (pad ++ str).dropRightWhile (· = '0')
    if trimmed.isEmpty then toString whole
    else s!"{whole}.{trimmed}"

private def parseChainOrDefault (chain? : Option String) :
    Option LeanKohaku.Swap.Tokens.ChainId :=
  match chain? with
  | none => some .mainnet
  | some s => LeanKohaku.Swap.Tokens.ChainId.fromString? s

private def chainIdToString : LeanKohaku.Swap.Tokens.ChainId → String
  | .mainnet => "mainnet"
  | .sepolia => "sepolia"

/-- Resolve a token argument (symbol or 0x address) into `(decimals, label)`
    for amount conversion / rendering. The pseudo-symbol `ETH` resolves to
    WETH semantics for swap purposes. Returns the resolved token (when a
    symbol) and the chain-specific address. Fails with a printable error. -/
private def resolveSwapToken (raw : String) (chain : LeanKohaku.Swap.Tokens.ChainId) :
    Except String (Option LeanKohaku.Swap.Tokens.Token × String) :=
  let s := raw.trimAscii.toString
  if s.startsWith "0x" || s.startsWith "0X" then
    .ok (none, s.toLower)
  else
    let sym := if s.toLower = "eth" then "WETH" else s
    match LeanKohaku.Swap.Tokens.findBySymbol sym with
    | none => .error s!"unknown token symbol: {raw}"
    | some t =>
        match LeanKohaku.Swap.Tokens.addressOn t chain with
        | none =>
            .error s!"no canonical address for {t.symbol} on {chainIdToString chain}"
        | some addr => .ok (some t, addr)

private def runSwapQuote (fromTok toTok amount : String) (chain? : Option String) :
    IO UInt32 := do
  match parseChainOrDefault chain? with
  | none =>
      let c := chain?.getD ""
      IO.eprintln s!"unknown chain: {c}"
      return 2
  | some chain =>
      match resolveSwapToken fromTok chain, resolveSwapToken toTok chain with
      | .error e, _ => IO.eprintln e; return 2
      | _, .error e => IO.eprintln e; return 2
      | .ok (tin?, tinAddr), .ok (tout?, toutAddr) =>
          -- decimals fall back to 18 for raw addresses
          let inDecimals := (tin?.map (·.decimals)).getD 18
          let outDecimals := (tout?.map (·.decimals)).getD 18
          match parseDecimalToBaseUnits amount inDecimals with
          | none => IO.eprintln s!"invalid amount: {amount}"; return 2
          | some amountIn =>
              let params : LeanKohaku.Encoding.Json.Json := .obj #[
                ("chainId", .str (chainIdToString chain)),
                ("tokenIn", .str tinAddr),
                ("tokenOut", .str toutAddr),
                ("amountIn", .num (Int.ofNat amountIn))
              ]
              match ← DaemonClient.call "swap.uniV3.quote" params with
              | .error err =>
                  IO.eprintln s!"daemon error {err.code}: {err.message}"
                  return 2
              | .ok r =>
                  let amtOut := (LeanKohaku.Encoding.Json.getField "amountOut" r
                                 >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  let fee := (LeanKohaku.Encoding.Json.getField "fee" r
                              >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  let router := (LeanKohaku.Encoding.Json.getField "router" r
                                 >>= LeanKohaku.Encoding.Json.asString).getD ""
                  let inLabel := (tin?.map (·.symbol)).getD tinAddr
                  let outLabel := (tout?.map (·.symbol)).getD toutAddr
                  IO.println s!"{amount} {inLabel} → {formatBaseUnits amtOut outDecimals} {outLabel}"
                  IO.println s!"  fee tier:  {fee} (= {fee} bps)"
                  IO.println s!"  venue:     Uniswap V3 SwapRouter02 {router}"
                  IO.println s!"  chainId:   {chainIdToString chain}"
                  IO.println s!"  amountOut: {amtOut} (base units)"
                  return 0

private def runSwapExec (fromTok toTok amount : String)
    (receiver? slippage? chain? : Option String) : IO UInt32 := do
  match parseChainOrDefault chain? with
  | none =>
      let c := chain?.getD ""
      IO.eprintln s!"unknown chain: {c}"
      return 2
  | some chain =>
      match resolveSwapToken fromTok chain, resolveSwapToken toTok chain with
      | .error e, _ => IO.eprintln e; return 2
      | _, .error e => IO.eprintln e; return 2
      | .ok (tin?, tinAddr), .ok (tout?, toutAddr) =>
          let inDecimals := (tin?.map (·.decimals)).getD 18
          match parseDecimalToBaseUnits amount inDecimals with
          | none => IO.eprintln s!"invalid amount: {amount}"; return 2
          | some amountIn =>
              -- slippage: percent string, e.g. "0.5" -> 50 bps. Default 0.5%.
              let slippageStr := slippage?.getD "0.5"
              -- Encode slippage as bps via parseDecimalToBaseUnits with 2 fractional digits.
              let slippageBps : Nat :=
                (parseDecimalToBaseUnits slippageStr 2).getD 50
              -- 1) quote
              let qparams : LeanKohaku.Encoding.Json.Json := .obj #[
                ("chainId", .str (chainIdToString chain)),
                ("tokenIn", .str tinAddr),
                ("tokenOut", .str toutAddr),
                ("amountIn", .num (Int.ofNat amountIn))
              ]
              match ← DaemonClient.call "swap.uniV3.quote" qparams with
              | .error err =>
                  IO.eprintln s!"daemon error (quote) {err.code}: {err.message}"
                  return 2
              | .ok q =>
                  let amtOut := (LeanKohaku.Encoding.Json.getField "amountOut" q
                                 >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  let fee := (LeanKohaku.Encoding.Json.getField "fee" q
                              >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  let amountOutMin :=
                    LeanKohaku.Invariants.Swap.applySlippageBps amtOut slippageBps
                  -- 2) need fromAddress: ask daemon for the default account.
                  let fromAddr ←
                    match ← DaemonClient.call "account.getDefault" with
                    | .ok j =>
                        pure ((LeanKohaku.Encoding.Json.getField "address" j
                               >>= LeanKohaku.Encoding.Json.asString).getD "")
                    | .error _ => pure ""
                  if fromAddr.isEmpty then
                    IO.eprintln "no default account set; run `leankohaku wallet use <name>` first"
                    return 2
                  let recipient := receiver?.getD fromAddr
                  let bparams : LeanKohaku.Encoding.Json.Json := .obj #[
                    ("chainId", .str (chainIdToString chain)),
                    ("fromAddress", .str fromAddr),
                    ("tokenIn", .str fromTok),
                    ("tokenOut", .str toTok),
                    ("amountIn", .num (Int.ofNat amountIn)),
                    ("amountOutMin", .num (Int.ofNat amountOutMin)),
                    ("fee", .num (Int.ofNat fee)),
                    ("recipient", .str recipient)
                  ]
                  match ← DaemonClient.call "swap.uniV3.build" bparams with
                  | .error err =>
                      IO.eprintln s!"daemon error (build) {err.code}: {err.message}"
                      return 2
                  | .ok r =>
                      IO.println s!"# Uniswap V3 swap plan"
                      IO.println s!"#   in:           {amountIn} {fromTok} (base units)"
                      IO.println s!"#   quoted out:   {amtOut}"
                      IO.println s!"#   slippage:     {slippageBps} bps"
                      IO.println s!"#   amountOutMin: {amountOutMin}"
                      IO.println s!"#   fee tier:     {fee}"
                      IO.println s!"# The daemon returned the following txs."
                      IO.println s!"# Send each through the existing eoa.send / tx.decodeIntent /"
                      IO.println s!"# tx.simulate / ConfirmGate pipeline (slice B prints them as JSON;"
                      IO.println s!"# a TUI flow lands in a follow-up slice)."
                      match LeanKohaku.Encoding.Json.getField "approval" r with
                      | some (.obj _) =>
                          IO.println "## approval:"
                          IO.println (LeanKohaku.Encoding.Json.pretty
                            ((LeanKohaku.Encoding.Json.getField "approval" r).getD .null))
                      | _ => pure ()
                      IO.println "## swap:"
                      IO.println (LeanKohaku.Encoding.Json.pretty
                        ((LeanKohaku.Encoding.Json.getField "tx" r).getD .null))
                      return 0

/-- Parse a `0x`-prefixed (or bare) hex quantity to a `Nat`. Returns
    `none` on bad input. Used by `runBalances` to render uint256 balance
    strings as decimal token amounts. -/
private def hexQuantityToNat (s : String) : Option Nat :=
  -- Strip an optional 0x / 0X prefix and walk the remaining nibbles. We
  -- iterate the original string and skip the first 2 chars when present
  -- to avoid `String.drop`/`String.extract` slice-vs-string surface area
  -- in this toolchain.
  let chars := s.toList
  let body : List Char :=
    match chars with
    | '0' :: 'x' :: rest => rest
    | '0' :: 'X' :: rest => rest
    | _ => chars
  if body.isEmpty then none
  else body.foldl (init := some 0) fun acc c =>
    match acc with
    | none => none
    | some n =>
        let d? : Option Nat :=
          if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
          else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
          else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
          else none
        d?.map (fun d => n * 16 + d)

/-- Resolve the address to use for a balance query: explicit `--address`
    wins; otherwise we look up the default account name and resolve to its
    primary address via `account.list`. Returns `none` with an error
    message for the user. -/
private def resolveBalancesAddress (address? : Option String) :
    IO (Except String String) := do
  match address? with
  | some a => pure (.ok a)
  | none =>
      match ← readDefaultAccount with
      | none =>
          pure <| .error
            "no default account; pass --address 0x… or set one with `kohaku wallet use <name>`"
      | some name =>
          for e in (← fetchAccountList) do
            let n := (LeanKohaku.Encoding.Json.getField "name" e
                      >>= LeanKohaku.Encoding.Json.asString).getD ""
            if n = name then
              let addr := (LeanKohaku.Encoding.Json.getField "address" e
                           >>= LeanKohaku.Encoding.Json.asString).getD ""
              if addr.isEmpty then
                return .error s!"default account '{name}' has no address on file"
              else
                return .ok addr
          pure <| .error s!"default account '{name}' not found"

/-- Resolve the chain to query: explicit `--chain` wins; otherwise we ask
    the daemon for its current chain via `daemon.ping`. Falls back to
    mainnet on transport failure (consistent with `parseChainOrDefault`),
    but propagates a parse error for an explicit unknown name. -/
private def resolveBalancesChain (chain? : Option String) :
    IO (Option LeanKohaku.Swap.Tokens.ChainId) := do
  match chain? with
  | some s => pure (LeanKohaku.Swap.Tokens.ChainId.fromString? s)
  | none =>
      match ← DaemonClient.call "daemon.ping" with
      | .error _ => pure (some .mainnet)
      | .ok r =>
          let id := (LeanKohaku.Encoding.Json.getField "chainId" r
                     >>= LeanKohaku.Encoding.Json.asNat).getD 1
          if id = 11155111 then pure (some .sepolia)
          else if id = 1 then pure (some .mainnet)
          else pure (some .mainnet)

private def padRight (s : String) (n : Nat) : String :=
  if s.length ≥ n then s
  else s ++ String.mk (List.replicate (n - s.length) ' ')

private def runBalances
    (chain? : Option String) (address? : Option String) (json : Bool) :
    IO UInt32 := do
  match ← resolveBalancesChain chain? with
  | none =>
      let c := chain?.getD ""
      IO.eprintln s!"unknown chain: {c}"
      return 2
  | some chain =>
      match ← resolveBalancesAddress address? with
      | .error msg => IO.eprintln msg; return 2
      | .ok address =>
          let params : LeanKohaku.Encoding.Json.Json := .obj #[
            ("chainId", .str (chainIdToString chain)),
            ("address", .str address)
          ]
          match ← DaemonClient.call "swap.balances" params with
          | .error err =>
              IO.eprintln s!"daemon error {err.code}: {err.message}"
              return 2
          | .ok r =>
              if json then
                -- Print the daemon's full response as one compact JSON
                -- blob, then echo each balance entry on its own line for
                -- grep-friendly machine consumers. Reuses the daemon
                -- shape verbatim — no field synthesis on the CLI side.
                let arr := (LeanKohaku.Encoding.Json.getField "balances" r
                            >>= LeanKohaku.Encoding.Json.asArray).getD #[]
                IO.println (LeanKohaku.Encoding.Json.compact r)
                for e in arr do
                  IO.println (LeanKohaku.Encoding.Json.compact e)
                return 0
              else
                let arr := (LeanKohaku.Encoding.Json.getField "balances" r
                            >>= LeanKohaku.Encoding.Json.asArray).getD #[]
                IO.println s!"# chain: {chainIdToString chain}"
                IO.println s!"# address: {address}"
                IO.println (padRight "symbol" 8 ++ padRight "decimals" 10 ++
                            padRight "address" 44 ++ "balance")
                for e in arr do
                  let sym := (LeanKohaku.Encoding.Json.getField "symbol" e
                              >>= LeanKohaku.Encoding.Json.asString).getD "?"
                  let dec := (LeanKohaku.Encoding.Json.getField "decimals" e
                              >>= LeanKohaku.Encoding.Json.asNat).getD 18
                  let addrField :=
                    match LeanKohaku.Encoding.Json.getField "address" e with
                    | some (.str s) => s
                    | _ => "—"
                  let balHex := (LeanKohaku.Encoding.Json.getField "balance" e
                                 >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
                  let balN := (hexQuantityToNat balHex).getD 0
                  IO.println (padRight sym 8 ++ padRight (toString dec) 10 ++
                              padRight addrField 44 ++ formatBaseUnits balN dec)
                return 0

def run (args : List String) : IO UInt32 := do
  let (cmd, accountIdx?) := parseTop args
  -- Why: only commands listed in step 4 spec consume `--account`; others ignore it silently.
  match cmd with
  | .help       => IO.println helpText; return 0
  | .version    => IO.println s!"leankohaku {LeanKohaku.version}"; return 0
  | .policy topic => IO.println (policyText topic); return 0
  | .walletCreate typ name extra =>
      match typ with
      | "eoa" => eoaCreate name extra
      | "r1" =>
          match extra with
          | none => runR1WalletCreate name
          | some _ =>
              IO.eprintln s!"error: 'wallet create r1 {name}' takes no extra argument"
              return 2
      | _ =>
          IO.eprintln s!"error: unknown wallet type '{typ}' (expected: eoa | r1)"
          return 2
  | .walletImport name mnemonic path? =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: '{name}' is an R1 (TPM) wallet — import is only valid for EOA wallets"
          return 2
      | _ => eoaImport name mnemonic path?
  | .walletDeploy name =>
      match ← resolveSlotType name with
      | none =>
          IO.eprintln s!"error: unknown wallet '{name}'"
          return 2
      | some .eoa =>
          IO.eprintln s!"error: '{name}' is an EOA wallet — deploy is only valid for R1 wallets"
          return 2
      | some .tpm =>
          let chain ← NetworkConfig.currentChainName
          runR1WalletDeploy name chain
  | .walletList =>
      let padName (name : String) : String :=
        let pad := if name.length < 16 then String.mk (List.replicate (16 - name.length) ' ') else ""
        name ++ pad
      IO.println "TYPE  NAME              ADDRESS                                       LOCKED"
      match ← DaemonClient.call "eoa.list" with
      | .error err => IO.eprintln s!"  eoa.list failed: {err.message}"
      | .ok eoaList =>
          for entry in (LeanKohaku.Encoding.Json.asArray eoaList).getD #[] do
            let name := (LeanKohaku.Encoding.Json.getField "name" entry >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry >>= LeanKohaku.Encoding.Json.asString).getD ""
            let locked := (LeanKohaku.Encoding.Json.getField "locked" entry).bind (fun j => match j with | .bool b => some b | _ => none) |>.getD true
            let lockTag := if locked then "yes" else "no"
            IO.println s!"eoa   {padName name} {addr}  {lockTag}"
            match ← DaemonClient.call "eoa.account.list" (.obj #[("name", .str name)]) with
            | .error _ => pure ()
            | .ok r =>
                let accounts := (LeanKohaku.Encoding.Json.getField "accounts" r >>= LeanKohaku.Encoding.Json.asArray).getD #[]
                for acc in accounts do
                  let idx := (LeanKohaku.Encoding.Json.getField "index" acc >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  if idx = 0 then pure () else
                    let aAddr := (LeanKohaku.Encoding.Json.getField "address" acc >>= LeanKohaku.Encoding.Json.asString).getD ""
                    IO.println s!"eoa   {padName s!"{name}/#{idx}"} {aAddr}  -"
      match ← DaemonClient.call "tpm.listSepoliaAddresses" with
      | .error err => IO.eprintln s!"  tpm.listSepoliaAddresses failed: {err.message}"
      | .ok tpmList =>
          for entry in (LeanKohaku.Encoding.Json.asArray tpmList).getD #[] do
            let name := (LeanKohaku.Encoding.Json.getField "name" entry >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry >>= LeanKohaku.Encoding.Json.asString).getD ""
            let addrTxt := if addr.isEmpty then "(no address; deploy first)" else addr
            IO.println s!"r1    {padName name} {addrTxt}  -"
      pure 0
  | .walletShow name =>
      match ← resolveSlotType name with
      | some .eoa => prettyEoaShow name
      | some .tpm => prettyTpmShow name
      | none =>
          IO.eprintln s!"error: unknown wallet '{name}'"
          return 2
  | .walletShowAll =>
      let wallets ← listAllWallets
      if wallets.isEmpty then
        IO.println "(no wallets found)"
        return 0
      let mut first := true
      for (n, t) in wallets do
        if !first then IO.println ""
        first := false
        match t with
        | .eoa => let _ ← prettyEoaShow n
        | .tpm => let _ ← prettyTpmShow n
      pure 0
  | .walletAddress name =>
      match ← resolveSlotType name with
      | some .eoa =>
          DaemonClient.printCall "eoa.address" (.obj #[("name", .str name)])
      | some .tpm =>
          match ← DaemonClient.call "tpm.listSepoliaAddresses" with
          | .error err =>
              IO.eprintln s!"daemon error {err.code}: {err.message}"
              pure 2
          | .ok r =>
              let entries := (LeanKohaku.Encoding.Json.asArray r).getD #[]
              let addr := entries.findSome? fun e =>
                let n := (LeanKohaku.Encoding.Json.getField "name" e
                          >>= LeanKohaku.Encoding.Json.asString).getD ""
                if n = name then
                  LeanKohaku.Encoding.Json.getField "address" e
                    >>= LeanKohaku.Encoding.Json.asString
                else none
              match addr with
              | some a => IO.println a; pure 0
              | none =>
                  IO.println "(no address; deploy first)"
                  pure 0
      | none =>
          IO.eprintln s!"error: unknown wallet '{name}'"
          return 2
  | .walletAddressAll =>
      -- Walk EOA wallets (with sub-accounts) then TPM wallets, one line each.
      match ← DaemonClient.call "eoa.list" with
      | .error err => IO.eprintln s!"  eoa.list failed: {err.message}"
      | .ok eoaList =>
          for entry in (LeanKohaku.Encoding.Json.asArray eoaList).getD #[] do
            let n := (LeanKohaku.Encoding.Json.getField "name" entry
                      >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry
                          >>= LeanKohaku.Encoding.Json.asString).getD ""
            IO.println s!"eoa  {n}  {addr}"
            match ← DaemonClient.call "eoa.account.list" (.obj #[("name", .str n)]) with
            | .error _ => pure ()
            | .ok r =>
                let accounts := (LeanKohaku.Encoding.Json.getField "accounts" r
                                >>= LeanKohaku.Encoding.Json.asArray).getD #[]
                for acc in accounts do
                  let idx := (LeanKohaku.Encoding.Json.getField "index" acc
                                >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  if idx = 0 then pure () else
                    let aAddr := (LeanKohaku.Encoding.Json.getField "address" acc
                                  >>= LeanKohaku.Encoding.Json.asString).getD ""
                    IO.println s!"eoa  {n}/#{idx}  {aAddr}"
      match ← DaemonClient.call "tpm.listSepoliaAddresses" with
      | .error err => IO.eprintln s!"  tpm.listSepoliaAddresses failed: {err.message}"
      | .ok tpmList =>
          for entry in (LeanKohaku.Encoding.Json.asArray tpmList).getD #[] do
            let n := (LeanKohaku.Encoding.Json.getField "name" entry
                      >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry
                          >>= LeanKohaku.Encoding.Json.asString).getD ""
            let addrTxt := if addr.isEmpty then "(no address; deploy first)" else addr
            IO.println s!"r1   {n}  {addrTxt}"
      pure 0
  | .walletUnlock name =>
      match ← resolveSlotType name with
      | some .eoa => eoaUnlock name
      | some .tpm =>
          IO.println "(r1 wallet — no unlock needed; signing prompts for the TPM PIN)"
          pure 0
      | none =>
          IO.eprintln s!"error: unknown wallet '{name}'"
          return 2
  | .walletLock name =>
      match ← resolveSlotType name with
      | some .eoa => DaemonClient.printCall "eoa.lock" (.obj #[("name", .str name)])
      | some .tpm =>
          IO.println "(r1 wallet — already locked between operations)"
          pure 0
      | none =>
          IO.eprintln s!"error: unknown wallet '{name}'"
          return 2
  | .walletUnlockAll =>
      let wallets ← listAllWallets
      let eoas := wallets.filter (fun (_, t) => t = .eoa)
      let tpms := wallets.filter (fun (_, t) => t = .tpm)
      -- Why: collect locked EOAs first; if everyone is already unlocked, skip the prompt.
      let mut locked : Array String := #[]
      let mut unlockedAlready : Array String := #[]
      match ← DaemonClient.call "eoa.list" with
      | .error err =>
          IO.eprintln s!"  eoa.list failed: {err.message}"
          return 2
      | .ok eoaList =>
          for entry in (LeanKohaku.Encoding.Json.asArray eoaList).getD #[] do
            let n := (LeanKohaku.Encoding.Json.getField "name" entry
                      >>= LeanKohaku.Encoding.Json.asString).getD ""
            let isLocked :=
              match LeanKohaku.Encoding.Json.getField "locked" entry with
              | some (.bool b) => b
              | _ => true
            if isLocked then locked := locked.push n
            else unlockedAlready := unlockedAlready.push n
      let totalEoa := eoas.size
      IO.println s!"Unlocking {totalEoa} EOA wallets…"
      if locked.isEmpty then
        for n in unlockedAlready do IO.println s!"  ✓ {n}  (already unlocked)"
        for (n, _) in tpms do IO.println s!"  -  {n}       (skipped: r1)"
        IO.println s!"Unlocked {unlockedAlready.size} of {totalEoa}. 0 wallets still locked."
        return 0
      let passphrase ← Passphrase.read "Master passphrase (will try against all locked EOA wallets): "
      let mut succeeded : Nat := unlockedAlready.size
      let mut failed : Array String := #[]
      for n in unlockedAlready do IO.println s!"  ✓ {n}  (already unlocked)"
      for n in locked do
        match ← DaemonClient.call "eoa.unlock"
            (.obj #[("name", .str n), ("passphrase", .str passphrase)]) with
        | .ok _ =>
            IO.println s!"  ✓ {n}"
            succeeded := succeeded + 1
        | .error _ =>
            IO.println s!"  ✗ {n}  (different passphrase; still locked)"
            failed := failed.push n
      for (n, _) in tpms do IO.println s!"  -  {n}       (skipped: r1)"
      let stillLocked := failed.size
      IO.println s!"Unlocked {succeeded} of {totalEoa}. {stillLocked} wallet(s) still locked."
      pure 0
  | .walletLockAll =>
      let wallets ← listAllWallets
      let mut locked : Nat := 0
      for (n, t) in wallets do
        match t with
        | .eoa =>
            match ← DaemonClient.call "eoa.lock" (.obj #[("name", .str n)]) with
            | .ok _ => IO.println s!"  ✓ {n}"; locked := locked + 1
            | .error err => IO.println s!"  ✗ {n}  ({err.message})"
        | .tpm => IO.println s!"  -  {n}  (skipped: r1)"
      IO.println s!"Locked {locked} EOA wallet(s)."
      pure 0
  | .walletHistoryAll scanLogs limit? chain? =>
      let mut first := true
      let mut anyShown := false
      match ← DaemonClient.call "eoa.list" with
      | .error err =>
          IO.eprintln s!"  eoa.list failed: {err.message}"
          return 2
      | .ok eoaList =>
          let entries := (LeanKohaku.Encoding.Json.asArray eoaList).getD #[]
          for entry in entries do
            let n := (LeanKohaku.Encoding.Json.getField "name" entry
                      >>= LeanKohaku.Encoding.Json.asString).getD ""
            if n.isEmpty then continue
            if !first then IO.println ""
            first := false
            anyShown := true
            IO.println s!"── {n} ──"
            runWalletHistoryFor n scanLogs limit? chain?
      -- Why: r1.send entries are written to <name>.ndjson by `r1SendFlow`
      -- (Server.lean:981, :1008), so R1 wallets get the same Layer-1 history
      -- as EOAs. Layer 2 scan uses the deployed R1 address.
      match ← DaemonClient.call "tpm.listSepoliaAddresses" with
      | .error err => IO.eprintln s!"  tpm.listSepoliaAddresses failed: {err.message}"
      | .ok r =>
          let tpms := (LeanKohaku.Encoding.Json.asArray r).getD #[]
          for entry in tpms do
            let n := (LeanKohaku.Encoding.Json.getField "name" entry
                      >>= LeanKohaku.Encoding.Json.asString).getD ""
            if n.isEmpty then continue
            if !first then IO.println ""
            first := false
            anyShown := true
            IO.println s!"── {n} (r1) ──"
            runR1WalletHistoryFor n scanLogs limit? chain?
      if !anyShown then IO.println "(no wallets found)"
      pure 0
  | .walletDelete name =>
      match ← resolveSlotType name with
      | some .eoa => eoaDelete name
      | some .tpm =>
          IO.eprintln s!"error: deleting an R1 (TPM) wallet via the CLI is not yet wired; remove the TPM blob under .leankohaku/ manually"
          return 2
      | none =>
          IO.eprintln s!"error: unknown wallet '{name}'"
          return 2
  | .walletReveal name =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: '{name}' is a TPM/R1 wallet — there is no BIP-39 mnemonic to reveal."
          return 2
      | none =>
          IO.eprintln s!"error: unknown wallet '{name}'"
          return 2
      | some .eoa =>
          IO.eprintln "⚠  About to print a BIP-39 mnemonic to your terminal."
          IO.eprintln "   Anyone with these words controls the funds. Make sure no one is looking,"
          IO.eprintln "   no screen recording is running, and clear scrollback after you copy them."
          IO.eprint s!"   Type the wallet name '{name}' to confirm: "
          let stdin ← IO.getStdin
          let confirm ← stdin.getLine
          let typed := confirm.trimRight
          if typed != name then
            IO.eprintln "aborted: confirmation did not match wallet name."
            return 2
          let passphrase ← Passphrase.read s!"Passphrase for {name}: "
          match ← DaemonClient.call "eoa.revealMnemonic"
              (.obj #[("name", .str name), ("passphrase", .str passphrase)]) with
          | .error err =>
              IO.eprintln s!"reveal failed: daemon error {err.code}: {err.message}"
              return 2
          | .ok result =>
              let words := (LeanKohaku.Encoding.Json.getField "mnemonic" result
                            >>= LeanKohaku.Encoding.Json.asArray).getD #[]
              let phrase :=
                String.intercalate " " <|
                  (words.map fun w => (LeanKohaku.Encoding.Json.asString w).getD "").toList
              IO.println ""
              IO.println phrase
              IO.println ""
              IO.eprintln "✓ revealed. Clear your scrollback now (Ctrl-L is not enough)."
              return 0
  | .walletDerive name path =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: '{name}' is an R1 (TPM) wallet — derive is only valid for EOA wallets"
          return 2
      | _ =>
          DaemonClient.printCall "eoa.derive" (.obj #[("name", .str name), ("path", .str path)])
  | .walletSignDigest name digest =>
      match ← resolveSlotType name with
      | some .tpm =>
          let pin ← LeanKohaku.Cli.Pin.read s!"PIN for {name}: "
          DaemonClient.printTextResult "tpm.signSepolia"
            (.obj #[("name", .str name), ("digest", .str digest), ("pin", .str pin)])
      | _ => eoaSignDigestCall name digest accountIdx?
  | .walletSignMessage name message path? =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: 'wallet sign-message' is not yet wired for R1 (TPM) wallets"
          return 2
      | _ => eoaSignMessage name message path? accountIdx?
  | .walletSignTx name txJson path? =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: 'wallet sign-tx' is not yet wired for R1 (TPM) wallets — use `kohaku send` instead"
          return 2
      | _ => eoaSignTx name txJson path? accountIdx?
  | .walletSignTypedData name json path? =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: '{name}' is an R1 (TPM) wallet — sign-typed-data is only valid for EOA wallets (TPM keys are P-256, not secp256k1)"
          return 2
      | _ => eoaSignTypedData name json path? accountIdx?
  | .networkShow =>
      IO.println (← NetworkConfig.humanReport)
      return 0
  | .networkPath =>
      IO.println (← NetworkConfig.configPath)
      return 0
  | .networkSetRpc url transport? =>
      match transport? with
      | some t =>
          if NetworkConfig.parseTransport? t |>.isNone then
            IO.eprintln s!"invalid transport {t}; expected one of: loopback, direct, tor"
            return 2
          else
            NetworkConfig.setRpcUrl url (some t)
            IO.println s!"set rpc_url={url} rpc_transport={t} in {← NetworkConfig.configPath}"
            return 0
      | none =>
          NetworkConfig.setRpcUrl url none
          IO.println s!"set rpc_url={url} in {← NetworkConfig.configPath}"
          return 0
  | .networkSetLightclient url =>
      NetworkConfig.setRpcUrl url (some "loopback")
      IO.println s!"set rpc_url={url} rpc_transport=loopback in {← NetworkConfig.configPath}"
      IO.println "note: light-client URL must already be reachable on loopback"
      return 0
  | .networkSetPolicy policy =>
      match LeanKohaku.Privacy.NetworkPolicy.parsePolicy policy with
      | none =>
          let names := String.intercalate ", " LeanKohaku.Privacy.NetworkPolicy.policyNames
          IO.eprintln s!"invalid network policy {policy}; expected one of: {names}"
          return 2
      | some _ =>
          NetworkConfig.setPolicy policy
          IO.println s!"set network_policy={policy} in {← NetworkConfig.configPath}"
          return 0
  | .networkUnsetRpc =>
      NetworkConfig.unsetRpc
      IO.println s!"cleared rpc_url/rpc_transport in {← NetworkConfig.configPath}"
      return 0
  | .networkSetEnsRpc url =>
      NetworkConfig.setEnsRpcUrl url
      IO.println s!"set ens_rpc_url={url} in {← NetworkConfig.configPath}"
      IO.println "note: ENS resolution always queries mainnet regardless of operating chain"
      return 0
  | .networkUnsetEnsRpc =>
      NetworkConfig.unsetEnsRpc
      IO.println s!"cleared ens_rpc_url in {← NetworkConfig.configPath}"
      return 0
  | .networkSetRpcChain chain url transport? =>
      match transport? with
      | some t =>
          if NetworkConfig.parseTransport? t |>.isNone then
            IO.eprintln s!"invalid transport {t}; expected one of: loopback, direct, tor"
            return 2
          else
            NetworkConfig.setChainRpcUrl chain url (some t)
            IO.println s!"set rpc_urls.{chain}.url={url} rpc_urls.{chain}.transport={t} in {← NetworkConfig.configPath}"
            return 0
      | none =>
          NetworkConfig.setChainRpcUrl chain url none
          IO.println s!"set rpc_urls.{chain}={url} in {← NetworkConfig.configPath}"
          return 0
  | .networkUnsetRpcChain chain =>
      NetworkConfig.unsetChainRpcUrl chain
      IO.println s!"cleared rpc_urls.{chain} in {← NetworkConfig.configPath}"
      return 0
  | .networkMonitor =>
      IO.println (← NetworkConfig.humanReport)
      match ← NetworkConfig.networkLogPath with
      | none =>
          IO.println "Network event log is disabled (LEANKOHAKU_NETWORK_LOG=0)."
          IO.println "Re-run without that override to use the default log path."
          return 0
      | some path =>
          let fp : System.FilePath := path
          match fp.parent with
          | some parent => try IO.FS.createDirAll parent catch _ => pure ()
          | none => pure ()
          unless ← fp.pathExists do
            try
              let h ← IO.FS.Handle.mk fp .append
              h.flush
            catch _ => pure ()
          IO.println s!"--- tailing {path}  (Ctrl-C to exit) ---"
          let child ← IO.Process.spawn
            { cmd := "tail",
              args := #["-n", "200", "-F", path],
              stdin := .null,
              stdout := .piped,
              stderr := .inherit }
          streamNetLog child.stdout
          child.wait
  | .doctor     => IO.println doctorText; return 0
  | .policyCheck policy peer purpose transport =>
      IO.println (policyCheckText policy peer purpose transport)
      return 0
  | .rpcCheck policy backend transport method =>
      IO.println (rpcCheckText policy backend transport method)
      return 0
  | .rpcMethods => IO.println rpcMethodsText; return 0
  | .decodeErc20 calldata =>
      IO.println (erc20DecodeText calldata)
      return 0
  | .endpointCheck mode kind scheme transport credentialed =>
      IO.println (endpointCheckText mode kind scheme transport credentialed)
      return 0
  | .daemonHelp walletName? =>
      IO.println (daemonHelpText walletName?)
      return 0
  | .daemonPing =>
      DaemonClient.printCall "daemon.ping"
  | .daemonVersion =>
      DaemonClient.printCall "daemon.version"
  | .daemonStop =>
      DaemonClient.printCall "daemon.shutdown"
  | .daemon =>
      runDaemonForeground
  | .walletHistory name scanLogs indexer? limit? chain? =>
      let limit := limit?.getD 50
      -- Why: account-filter via the parsed --account flag.
      let accountFilter? : Option Nat :=
        accountIdx?.bind (fun s => s.toNat?)
      let renderEntry (e : LeanKohaku.Encoding.Json.Json) : IO Unit := do
        let getStr (k : String) : String :=
          (LeanKohaku.Encoding.Json.getField k e >>= LeanKohaku.Encoding.Json.asString).getD ""
        let getNat (k : String) : Nat :=
          (LeanKohaku.Encoding.Json.getField k e >>= LeanKohaku.Encoding.Json.asNat).getD 0
        let kind := getStr "kind"
        let txHash := getStr "txHash"
        let ts := getNat "timestamp"
        let toAddr := getStr "to"
        let fromA := getStr "from"
        let valueStr := getStr "valueWei"
        let valueWei := valueStr.toNat?.getD 0
        let block := getStr "blockNumber"
        let status := getStr "status"
        let truncH := if txHash.length ≤ 14 then txHash
                      else (txHash.toList.take 10 |> String.mk) ++ "…"
        IO.println s!"  {ts}  [{kind}]  {truncH}  {fromA} → {toAddr}  {formatEth valueWei}  block={block}  status={status}"
      -- Layer 1: read local journal.
      let allEntries ←
        match ← DaemonClient.call "chain.history"
            (.obj #[("name", .str name),
                    ("limit", .num (Int.ofNat limit))]) with
        | .ok r =>
            pure ((LeanKohaku.Encoding.Json.asArray r).getD #[])
        | .error err =>
            IO.eprintln s!"daemon error {err.code}: {err.message}"
            pure #[]
      let filtered :=
        match accountFilter? with
        | none => allEntries
        | some idx =>
            allEntries.filter fun e =>
              ((LeanKohaku.Encoding.Json.getField "accountIndex" e
                >>= LeanKohaku.Encoding.Json.asNat).getD 0) = idx
      IO.println s!"Local journal ({filtered.size} entries):"
      for e in filtered do renderEntry e
      -- Layer 2: opt-in chunked eth_getLogs scan.
      if scanLogs then
        IO.println ""
        IO.println "Scanning chain logs (this may take a while)…"
        IO.println "  press Enter to cancel."
        match ← DaemonClient.call "eoa.show" (.obj #[("name", .str name)]) with
        | .error err =>
            IO.eprintln s!"  eoa.show failed: {err.message}"
        | .ok rec =>
            let addr := (LeanKohaku.Encoding.Json.getField "address" rec
                         >>= LeanKohaku.Encoding.Json.asString).getD ""
            -- Why: also include sub-account addresses.
            let subs ← match ← DaemonClient.call "eoa.account.list"
                  (.obj #[("name", .str name)]) with
              | .ok r =>
                  pure ((LeanKohaku.Encoding.Json.getField "accounts" r
                         >>= LeanKohaku.Encoding.Json.asArray).getD #[])
              | .error _ => pure #[]
            let mut addrs : Array LeanKohaku.Encoding.Json.Json :=
              if addr.isEmpty then #[] else #[.str addr]
            for a in subs do
              let aAddr := (LeanKohaku.Encoding.Json.getField "address" a
                            >>= LeanKohaku.Encoding.Json.asString).getD ""
              if !aAddr.isEmpty && aAddr ≠ addr then
                addrs := addrs.push (.str aAddr)
            -- Why: forward the user-selected chain so the daemon picks the
            -- matching RPC endpoint (or fails closed) instead of silently
            -- scanning the daemon's default chain.
            let baseFields : Array (String × LeanKohaku.Encoding.Json.Json) :=
              #[("addresses", .arr addrs), ("slotName", .str name)]
            let scanFields :=
              match chain? with
              | none => baseFields
              | some c => baseFields.push ("chain", .str c)
            -- Why: run the (potentially long) scan on a background task and
            -- watch stdin on another. If the user presses Enter before the
            -- scan finishes, send `chain.cancel` to the daemon — the scan
            -- handler aborts at the next chunk boundary and returns a
            -- partial result with `cancelled: true`.
            -- Surface the wall-clock cap so users know the scan auto-stops.
            let envCapS ← IO.getEnv "KOHAKU_SCAN_MAX_MS"
            let envCapMs : Nat :=
              match envCapS with
              | some s => (s.toNat?.getD 300000)
              | none => 300000
            let envCapSec : Nat :=
              let n := if envCapMs = 0 then 300000 else envCapMs
              n / 1000
            IO.println s!"  bounded by KOHAKU_SCAN_MAX_MS={envCapSec}s (default 300s); press Enter to cancel."
            let scanTask ← IO.asTask
              (DaemonClient.call "chain.scanTransfers" (.obj scanFields))
            let stdinTask ← IO.asTask (do
              let _ ← (← IO.getStdin).getLine
              pure ())
            -- Poll both until the scan completes; if stdin fires first, ask
            -- the daemon to cancel and keep waiting for the scan to return
            -- (it will, promptly, with the partial result).
            let mut cancelSent := false
            let mut done := false
            while !done do
              if ← IO.hasFinished scanTask then
                done := true
              else
                if !cancelSent && (← IO.hasFinished stdinTask) then
                  cancelSent := true
                  IO.println "  cancelling scan…"
                  discard <| DaemonClient.call "chain.cancel" (.obj #[])
                IO.sleep 100
            let scanRes ← IO.wait scanTask
            -- Best-effort: if the user never pressed Enter, the stdin task
            -- is still blocked in getLine. Lean has no portable way to kill
            -- it, but the process is about to exit anyway.
            match scanRes with
            | .error e =>
                IO.eprintln s!"  chain.scanTransfers task failed: {e}"
            | .ok (.error err) =>
                IO.eprintln s!"  chain.scanTransfers failed: {err.message}"
            | .ok (.ok r) =>
                let events := (LeanKohaku.Encoding.Json.getField "events" r
                               >>= LeanKohaku.Encoding.Json.asArray).getD #[]
                let cancelled :=
                  match LeanKohaku.Encoding.Json.getField "cancelled" r with
                  | some (.bool b) => b
                  | _ => false
                let timedOut :=
                  match LeanKohaku.Encoding.Json.getField "timedOut" r with
                  | some (.bool b) => b
                  | _ => false
                let respMaxMs := (LeanKohaku.Encoding.Json.getField "maxMs" r
                                  >>= LeanKohaku.Encoding.Json.asNat).getD 0
                let lastBlock := (LeanKohaku.Encoding.Json.getField "lastScannedBlock" r
                                  >>= LeanKohaku.Encoding.Json.asNat).getD 0
                IO.println s!"  on-chain Transfer events: {events.size}"
                for e in events do
                  let txHash := (LeanKohaku.Encoding.Json.getField "transactionHash" e
                                 >>= LeanKohaku.Encoding.Json.asString).getD ""
                  let blockN := (LeanKohaku.Encoding.Json.getField "blockNumber" e
                                 >>= LeanKohaku.Encoding.Json.asString).getD ""
                  IO.println s!"    {txHash}  block={blockN}"
                if cancelled then
                  IO.println s!"  scan cancelled at block {lastBlock}"
                if timedOut then
                  let durLabel : String :=
                    if respMaxMs > 0 then s!"after {respMaxMs / 1000}s"
                    else "after KOHAKU_SCAN_MAX_MS"
                  IO.println s!"  scan timed out {durLabel} at block {lastBlock}; rerun with --from-block {lastBlock + 1} to continue"
      -- Layer 3: opt-in indexer history.
      match indexer? with
      | none => pure ()
      | some idxName =>
          IO.println ""
          IO.println s!"⚠ leaking watch-address(es) to {idxName} (Layer 3); remove with: kohaku network deny-indexer {idxName}"
          match ← DaemonClient.call "eoa.show" (.obj #[("name", .str name)]) with
          | .error err =>
              IO.eprintln s!"  eoa.show failed: {err.message}"
          | .ok rec =>
              let addr := (LeanKohaku.Encoding.Json.getField "address" rec
                           >>= LeanKohaku.Encoding.Json.asString).getD ""
              match ← DaemonClient.call "chain.indexerHistory"
                  (.obj #[
                    ("address", .str addr),
                    ("indexer", .str idxName)
                  ]) with
              | .error err =>
                  IO.eprintln s!"  chain.indexerHistory failed: {err.message}"
              | .ok r =>
                  IO.println (LeanKohaku.Encoding.Json.pretty r)
      pure 0
  | .networkAllowIndexer indexerName url =>
      let resolved :=
        if url.isEmpty then
          if indexerName = "etherscan" then "https://api.etherscan.io/v2/api"
          else url
        else url
      if resolved.isEmpty then
        IO.eprintln s!"unknown indexer '{indexerName}'; provide a URL: kohaku network allow-indexer {indexerName} <url>"
        return 2
      NetworkConfig.allowIndexer indexerName resolved
      IO.println s!"allowed indexer {indexerName} url={resolved}"
      IO.println s!"  set LEANKOHAKU_{indexerName.toUpper}_KEY=<api-key> in your env to enable lookups"
      pure 0
  | .networkDenyIndexer indexerName =>
      NetworkConfig.denyIndexer indexerName
      IO.println s!"removed indexer {indexerName}"
      pure 0
  | .walletAccountList name =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: '{name}' is an R1 (TPM) wallet — account list is only valid for EOA wallets"
          return 2
      | _ => DaemonClient.printCall "eoa.account.list" (.obj #[("name", .str name)])
  | .walletAccountAdd name path? =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: '{name}' is an R1 (TPM) wallet — account add is only valid for EOA wallets"
          return 2
      | _ =>
        let passphrase ← Passphrase.read
        let base : Array (String × LeanKohaku.Encoding.Json.Json) := #[
          ("name", .str name),
          ("passphrase", .str passphrase)
        ]
        let fields :=
          match path? with
          | none => base
          | some p => base.push ("path", .str p)
        DaemonClient.printCall "eoa.account.add" (.obj fields)
  | .walletAccountRm name index =>
      match ← resolveSlotType name with
      | some .tpm =>
          IO.eprintln s!"error: '{name}' is an R1 (TPM) wallet — account rm is only valid for EOA wallets"
          return 2
      | _ =>
        match index.toNat? with
        | none =>
            IO.eprintln s!"invalid account index (expected non-negative integer): {index}"
            return 2
        | some n =>
            let passphrase ← Passphrase.read "Passphrase to remove account: "
            DaemonClient.printCall "eoa.account.rm"
              (.obj #[
                ("name", .str name),
                ("passphrase", .str passphrase),
                ("index", .num (Int.ofNat n))
              ])
  | .balance a  =>
      match ← resolveAddressOrName a with
      | .error err =>
          IO.eprintln s!"invalid balance address: {err}"
          return 2
      | .ok addr =>
          DaemonClient.printCall "chain.balance" (.obj #[("address", .str addr)])
  | .balanceAll =>
      let printRow (kind nameCol addr : String) (lockTag : String) : IO Nat := do
        if validAddressString addr then
          match ← DaemonClient.call "chain.balance" (.obj #[("address", .str addr)]) with
          | .error err =>
              IO.println s!"  [{kind}] {nameCol} {addr}  ERROR: {err.message}{lockTag}"
              pure 0
          | .ok r =>
              let hex := (LeanKohaku.Encoding.Json.getField "balance" r >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
              let wei := (hexWeiToNat hex).getD 0
              IO.println s!"  [{kind}] {nameCol} {addr}  {formatEth wei}{lockTag}"
              pure wei
        else
          IO.println s!"  [{kind}] {nameCol} (no address; deploy first){lockTag}"
          pure 0
      let padName (name : String) : String :=
        let pad := if name.length < 16 then String.mk (List.replicate (16 - name.length) ' ') else ""
        name ++ pad
      let eoaResult ← DaemonClient.call "eoa.list"
      let tpmResult ← DaemonClient.call "tpm.listSepoliaAddresses"
      IO.println "Address balances (Sepolia):"
      IO.println ""
      let mut totalEoa : Nat := 0
      let mut totalTpm : Nat := 0
      let mut anyShown := false
      match eoaResult with
      | .error err =>
          IO.eprintln s!"  eoa.list failed: {err.message}"
      | .ok eoaList =>
          for entry in (LeanKohaku.Encoding.Json.asArray eoaList).getD #[] do
            anyShown := true
            let name := (LeanKohaku.Encoding.Json.getField "name" entry >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry >>= LeanKohaku.Encoding.Json.asString).getD ""
            let locked := (LeanKohaku.Encoding.Json.getField "locked" entry).bind (fun j => match j with | .bool b => some b | _ => none) |>.getD true
            let lockTag := if locked then " [locked]" else ""
            let wei ← printRow "eoa" (padName name) addr lockTag
            totalEoa := totalEoa + wei
            -- Why: walk sub-accounts so multi-account slots show every derived address.
            match ← DaemonClient.call "eoa.account.list" (.obj #[("name", .str name)]) with
            | .error _ => pure ()
            | .ok r =>
                let accounts := (LeanKohaku.Encoding.Json.getField "accounts" r >>= LeanKohaku.Encoding.Json.asArray).getD #[]
                for acc in accounts do
                  let idx := (LeanKohaku.Encoding.Json.getField "index" acc >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  if idx = 0 then pure () else
                    let aAddr := (LeanKohaku.Encoding.Json.getField "address" acc >>= LeanKohaku.Encoding.Json.asString).getD ""
                    let label := (LeanKohaku.Encoding.Json.getField "label" acc >>= LeanKohaku.Encoding.Json.asString).getD s!"#{idx}"
                    let subName := s!"{name}/{label}"
                    let subWei ← printRow "eoa" (padName subName) aAddr ""
                    totalEoa := totalEoa + subWei
      match tpmResult with
      | .error err =>
          IO.eprintln s!"  tpm.listSepoliaAddresses failed: {err.message}"
      | .ok tpmList =>
          for entry in (LeanKohaku.Encoding.Json.asArray tpmList).getD #[] do
            anyShown := true
            let name := (LeanKohaku.Encoding.Json.getField "name" entry >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry >>= LeanKohaku.Encoding.Json.asString).getD ""
            let wei ← printRow "tpm" (padName name) addr ""
            totalTpm := totalTpm + wei
      if !anyShown then
        IO.println "  (no wallets found)"
      IO.println ""
      IO.println s!"  EOA total: {formatEth totalEoa}"
      IO.println s!"  TPM/R1 total: {formatEth totalTpm}"
      let publicTotal := totalEoa + totalTpm
      IO.println s!"  Public total:    {formatEth publicTotal}"
      IO.println ""
      -- Why: only prompt for the PP passphrase if a secret is on disk.
      if ← LeanKohaku.Wallet.PpSecretStore.existsOnDisk then
        IO.println "Shielded balance (Privacy Pools v1):"
        let passphrase ← Passphrase.read "Passphrase for shielded balance: "
        match ← DaemonClient.call "shielded.balance"
            (.obj #[("passphrase", .str passphrase)]) with
        | .error err =>
            IO.println s!"  (shielded.balance failed: {err.message})"
            IO.println ""
            IO.println s!"Grand total: {formatEth publicTotal}"
        | .ok result =>
            let resultField :=
              match LeanKohaku.Encoding.Json.getField "result" result with
              | some r => r
              | none => result
            let entries :=
              (LeanKohaku.Encoding.Json.getField "balances" resultField
                >>= LeanKohaku.Encoding.Json.asArray).getD #[]
            let mut confirmed : Nat := 0
            let mut pending : Nat := 0
            for entry in entries do
              let amountHex := (LeanKohaku.Encoding.Json.getField "amount" entry
                                >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
              let wei := (hexWeiToNat amountHex).getD 0
              let tag := (LeanKohaku.Encoding.Json.getField "tag" entry
                          >>= LeanKohaku.Encoding.Json.asString).getD ""
              if tag = "pending" then pending := pending + wei
              else confirmed := confirmed + wei
            let shieldedTotal := confirmed + pending
            IO.println s!"  confirmed:       {formatEth confirmed}"
            IO.println s!"  pending:         {formatEth pending}"
            IO.println s!"  total shielded:  {formatEth shieldedTotal}"
            IO.println ""
            IO.println s!"Grand total: {formatEth (publicTotal + shieldedTotal)}"
      else
        IO.println "(no shielded secret stored — run kohaku shield <wallet> <eth> to bootstrap)"
        IO.println ""
        IO.println s!"Grand total: {formatEth publicTotal}"
      pure 0
  | .listAll =>
      let padName (name : String) : String :=
        let pad := if name.length < 20 then String.mk (List.replicate (20 - name.length) ' ') else ""
        name ++ pad
      IO.println "Wallets:"
      IO.println ""
      match ← DaemonClient.call "eoa.list" with
      | .error err => IO.eprintln s!"  eoa.list failed: {err.message}"
      | .ok eoaList =>
          for entry in (LeanKohaku.Encoding.Json.asArray eoaList).getD #[] do
            let name := (LeanKohaku.Encoding.Json.getField "name" entry >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry >>= LeanKohaku.Encoding.Json.asString).getD ""
            let locked := (LeanKohaku.Encoding.Json.getField "locked" entry).bind (fun j => match j with | .bool b => some b | _ => none) |>.getD true
            let lockTag := if locked then "  [locked]" else ""
            IO.println s!"  [eoa] {padName name} {addr}{lockTag}"
            match ← DaemonClient.call "eoa.account.list" (.obj #[("name", .str name)]) with
            | .error _ => pure ()
            | .ok r =>
                let accounts := (LeanKohaku.Encoding.Json.getField "accounts" r >>= LeanKohaku.Encoding.Json.asArray).getD #[]
                for acc in accounts do
                  let idx := (LeanKohaku.Encoding.Json.getField "index" acc >>= LeanKohaku.Encoding.Json.asNat).getD 0
                  if idx = 0 then pure () else
                    let aAddr := (LeanKohaku.Encoding.Json.getField "address" acc >>= LeanKohaku.Encoding.Json.asString).getD ""
                    let path := (LeanKohaku.Encoding.Json.getField "path" acc >>= LeanKohaku.Encoding.Json.asString).getD ""
                    let label := (LeanKohaku.Encoding.Json.getField "label" acc >>= LeanKohaku.Encoding.Json.asString).getD ""
                    let labelTxt := if label.isEmpty then "" else s!"  ({label})"
                    IO.println s!"        └ #{idx}{labelTxt}  {aAddr}  {path}"
      IO.println ""
      match ← DaemonClient.call "tpm.listSepoliaAddresses" with
      | .error err => IO.eprintln s!"  tpm.listSepoliaAddresses failed: {err.message}"
      | .ok tpmList =>
          for entry in (LeanKohaku.Encoding.Json.asArray tpmList).getD #[] do
            let name := (LeanKohaku.Encoding.Json.getField "name" entry >>= LeanKohaku.Encoding.Json.asString).getD "?"
            let addr := (LeanKohaku.Encoding.Json.getField "address" entry >>= LeanKohaku.Encoding.Json.asString).getD ""
            let addrTxt := if addr.isEmpty then "(no address; deploy first)" else addr
            IO.println s!"  [tpm] {padName name} {addrTxt}"
      IO.println ""
      IO.println "Tip: `kohaku balance -a` adds Sepolia balances."
      pure 0
  | .nonce a =>
      if validAddressString a then
        DaemonClient.printCall "chain.nonce" (.obj #[("address", .str a)])
      else
        IO.eprintln s!"invalid nonce address: {a}"
        return 2
  | .tokenBalance token owner =>
      if validAddressString token && validAddressString owner then
        DaemonClient.printCall "chain.tokenBalance"
          (.obj #[("token", .str token), ("owner", .str owner)])
      else
        IO.eprintln s!"invalid token-balance arguments: token={token} owner={owner}"
        return 2
  | .gasPrice =>
      printFeeField "chain.gasPrice" "gasPrice"
  | .priorityFee =>
      printFeeField "chain.maxPriorityFeePerGas" "maxPriorityFeePerGas"
  | .estimateGas txJson =>
      match LeanKohaku.Encoding.Json.parse txJson with
      | .error err =>
          IO.eprintln s!"invalid estimate-gas transaction JSON: {err}"
          return 2
      | .ok tx =>
          DaemonClient.printCall "chain.estimateGas" (.obj #[("tx", tx)])
  | .broadcast rawTx =>
      match decodeHex rawTx with
      | some bytes =>
          if bytes.isEmpty then
            IO.eprintln "invalid raw transaction: empty hex"
            return 2
          else
            DaemonClient.printCall "chain.sendRawTransaction" (.obj #[("raw", .str rawTx)])
      | none =>
          IO.eprintln "invalid raw transaction hex"
          return 2
  | .send to amount fromWallet? =>
      -- Wallet selection precedence:
      --   1. `from <wallet> send …` (positional verb, fromWallet?)
      --   2. `--account <wallet>` (parsed at top level into accountIdx?)
      --   3. default wallet from `kohaku wallet use <wallet>`
      let walletId? : Option String ←
        match fromWallet?, accountIdx? with
        | some w, _ => pure (some w)
        | none, some w => pure (some w)
        | none, none => readDefaultAccount
      match walletId? with
      | none =>
          IO.eprintln "no default account; run: kohaku account use <wallet>  (or pass --account <wallet>)"
          return 2
      | some walletId =>
          -- Parse `<slot>` or `<slot>/<index>`.
          let parts := walletId.splitOn "/"
          let (slotName, subIdx?) :=
            match parts with
            | [s] => (s, none)
            | [s, i] => (s, some i)
            | _ => (walletId, none)
          match LeanKohaku.Invariants.EthAmount.parseEthToWei amount with
          | .error err =>
              IO.eprintln s!"invalid send amount (expected ETH like 0.001): {err}"
              return 2
          | .ok valueNat =>
              match ← resolveSlotType slotName with
              | none =>
                  IO.eprintln s!"unknown wallet: {slotName} (not in eoa.list or tpm.listSepoliaAddresses)"
                  return 2
              | some .eoa =>
                  match ← resolveAddressOrName to with
                  | .error err =>
                      IO.eprintln s!"invalid send recipient: {err}"
                      return 2
                  | .ok toResolved =>
                      -- Validate sub-account index if given.
                      match subIdx? with
                      | none => dispatchEoaSend slotName toResolved valueNat none none
                      | some s =>
                          match s.toNat? with
                          | none =>
                              IO.eprintln s!"invalid sub-account index: {s}"
                              return 2
                          | some _ =>
                              dispatchEoaSend slotName toResolved valueNat none (some s)
              | some .tpm =>
                  match subIdx? with
                  | some _ =>
                      IO.eprintln s!"sub-account form <slot>/<index> is not supported for TPM/R1 wallets ({slotName})"
                      return 2
                  | none =>
                      match ← resolveAddressOrName to with
                      | .error err =>
                          IO.eprintln s!"invalid send recipient: {err}"
                          return 2
                      | .ok toResolved =>
                          let pin ← LeanKohaku.Cli.Pin.read s!"PIN for {slotName}: "
                          let rc ← DaemonClient.printTextResult "r1.sendEthSepolia"
                            (.obj #[("name", .str slotName),
                                    ("to", .str toResolved),
                                    ("amountEth", .str amount),
                                    ("pin", .str pin)])
                          if rc = 0 then
                            match ← DaemonClient.call "tpm.listSepoliaAddresses" with
                            | .ok r =>
                                let entries := (LeanKohaku.Encoding.Json.asArray r).getD #[]
                                let addr := entries.foldl (init := "") fun acc e =>
                                  if !acc.isEmpty then acc
                                  else
                                    let n := (LeanKohaku.Encoding.Json.getField "name" e
                                              >>= LeanKohaku.Encoding.Json.asString).getD ""
                                    if n = slotName then
                                      (LeanKohaku.Encoding.Json.getField "address" e
                                        >>= LeanKohaku.Encoding.Json.asString).getD ""
                                    else acc
                                if !addr.isEmpty then
                                  match ← DaemonClient.call "chain.balance"
                                      (.obj #[("address", .str addr)]) with
                                  | .ok b =>
                                      let hex := (LeanKohaku.Encoding.Json.getField "balance" b
                                                  >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
                                      let wei := (hexWeiToNat hex).getD 0
                                      IO.println s!"  remaining: {formatEth wei}  ({slotName})"
                                  | .error _ => pure ()
                            | .error _ => pure ()
                          pure rc
  | .accountUse wallet =>
      match ← resolveSlotType wallet with
      | none =>
          IO.eprintln s!"unknown wallet: {wallet} (not in eoa.list or tpm.listSepoliaAddresses)"
          return 2
      | some _ =>
          writeDefaultAccount wallet
          IO.println s!"default account set: {wallet}"
          return 0
  | .accountCurrent =>
      match ← readDefaultAccount with
      | none =>
          IO.println "no default account set; run: kohaku account use <wallet>"
          return 0
      | some w =>
          let slotName := (w.splitOn "/").headD w
          match ← resolveSlotType slotName with
          | none =>
              IO.println s!"default account: {w}  (WARNING: not currently registered)"
              return 0
          | some t =>
              let kindStr := match t with | .eoa => "eoa" | .tpm => "tpm"
              -- Print a resolved address best-effort.
              let method := match t with | .eoa => "eoa.address" | .tpm => "tpm.listSepoliaAddresses"
              let addr ← match t with
                | .eoa =>
                    match ← DaemonClient.call "eoa.address" (.obj #[("name", .str slotName)]) with
                    | .ok r =>
                        -- Why: daemon returns bare JSON string for eoa.address.
                        match LeanKohaku.Encoding.Json.asString r with
                        | some s => pure s
                        | none =>
                            pure ((LeanKohaku.Encoding.Json.getField "address" r
                                   >>= LeanKohaku.Encoding.Json.asString).getD "")
                    | .error _ => pure ""
                | .tpm =>
                    match ← DaemonClient.call "tpm.listSepoliaAddresses" with
                    | .ok r =>
                        let entries := (LeanKohaku.Encoding.Json.asArray r).getD #[]
                        let found := entries.findSome? fun e =>
                          let n := (LeanKohaku.Encoding.Json.getField "name" e
                                    >>= LeanKohaku.Encoding.Json.asString).getD ""
                          if n = slotName then
                            LeanKohaku.Encoding.Json.getField "address" e
                              >>= LeanKohaku.Encoding.Json.asString
                          else none
                        pure (found.getD "")
                    | .error _ => pure ""
              let _ := method  -- silence unused
              IO.println s!"default account: {w}  type={kindStr}  address={addr}"
              return 0
  | .accountListNames =>
      printAccountListNames
  | .accountListTypedNames =>
      printAccountListTypedNames
  | .accountListIndices wallet? =>
      printAccountListIndices wallet?
  | .accountListWalletIndices withAddresses wallet? =>
      printAccountListWalletIndices withAddresses wallet?
  | .shieldedBalance =>
      let passphrase ← Passphrase.read
      match ← DaemonClient.call "shielded.balance" (.obj #[("passphrase", .str passphrase)]) with
      | .ok result =>
          let resultField :=
            match LeanKohaku.Encoding.Json.getField "result" result with
            | some r => r
            | none => result
          match LeanKohaku.Encoding.Json.getField "balances" resultField >>= LeanKohaku.Encoding.Json.asArray with
          | none =>
              IO.println (LeanKohaku.Encoding.Json.pretty result)
              pure 0
          | some entries =>
              let mut confirmed : Nat := 0
              let mut pending : Nat := 0
              for entry in entries do
                let amountHex := (LeanKohaku.Encoding.Json.getField "amount" entry >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
                let wei := (hexWeiToNat amountHex).getD 0
                let tag := (LeanKohaku.Encoding.Json.getField "tag" entry >>= LeanKohaku.Encoding.Json.asString).getD ""
                if tag = "pending" then pending := pending + wei
                else confirmed := confirmed + wei
              IO.println s!"Shielded balance (Privacy Pools v1, Sepolia)"
              IO.println s!"  confirmed: {formatEth confirmed}  ({confirmed} wei)"
              if pending > 0 then
                IO.println s!"  pending:   {formatEth pending}  ({pending} wei)"
                IO.println s!"  total:     {formatEth (confirmed + pending)}"
              pure 0
      | .error err =>
          IO.eprintln s!"daemon error {err.code}: {err.message}"
          pure 2
  | .shieldedDeposit walletName amountEth =>
      -- Privacy Pools v1 deposit requires a secp256k1 EOA signer. TPM/R1
      -- wallets hold P-256 keys behind a smart-account wrapper, which the
      -- current daemon `shielded.deposit` path can't drive. Reject early
      -- with a clear message instead of prompting for a passphrase the
      -- TPM wallet doesn't have.
      match ← resolveSlotType walletName with
      | none =>
          IO.eprintln s!"unknown wallet: {walletName}"
          return 2
      | some .tpm =>
          IO.eprintln s!"'{walletName}' is a TPM/R1 wallet; shield deposits are only supported from EOA wallets today."
          IO.eprintln "  The Privacy Pools v1 deposit path in the daemon needs a secp256k1 EOA signer."
          IO.eprintln "  Use an EOA wallet, e.g.:  kohaku shield bbqTest 0.04"
          IO.eprintln "  See `kohaku list` for the [eoa] entries."
          return 2
      | some .eoa => pure ()
      -- Two distinct secrets are involved here:
      --   1. The EOA slot's passphrase (decrypts the funding key in the daemon).
      --   2. The Privacy Pools mnemonic passphrase (encrypts the PP secret on disk).
      -- They are kept separate so a leak of one does not compromise the other.
      let eoaPass ← Passphrase.read s!"Passphrase for EOA '{walletName}': "
      match ← DaemonClient.call "eoa.unlock"
          (.obj #[("name", .str walletName), ("passphrase", .str eoaPass)]) with
      | .error err =>
          IO.eprintln s!"🔒 EOA unlock failed for '{walletName}': {err.message}"
          pure 2
      | .ok _ =>
          let ppPass ← Passphrase.read "Privacy Pool passphrase: "
          match ← DaemonClient.call "shielded.deposit"
              (.obj #[
                ("name", .str walletName),
                ("amountEth", .str amountEth),
                ("passphrase", .str ppPass)
              ]) with
          | .error err =>
              IO.eprintln s!"daemon error {err.code}: {err.message}"
              pure 2
          | .ok result =>
              let getStr (j : LeanKohaku.Encoding.Json.Json) (k : String) : String :=
                (LeanKohaku.Encoding.Json.getField k j
                  >>= LeanKohaku.Encoding.Json.asString).getD ""
              let getNatHex (j : LeanKohaku.Encoding.Json.Json) (k : String) : Nat :=
                (hexWeiToNat (getStr j k)).getD 0
              let sent := (LeanKohaku.Encoding.Json.getField "sent" result
                           >>= LeanKohaku.Encoding.Json.asArray).getD #[]
              if sent.isEmpty then
                IO.eprintln "shielded.deposit returned no broadcast txs; raw response below:"
                IO.eprintln (LeanKohaku.Encoding.Json.pretty result)
                pure 1
              else
                IO.println "✓ Shielded deposit (Privacy Pools v1, Sepolia):"
                IO.println ""
                IO.println s!"  wallet:    {walletName}"
                IO.println s!"  amount:    {amountEth} ETH"
                IO.println ""
                IO.println "  Transactions:"
                let mut anyRevert := false
                for tx in sent do
                  let txHash := getStr tx "txHash"
                  let status := getStr tx "status"
                  let block  := getNatHex tx "blockNumber"
                  let gas    := getNatHex tx "gasUsed"
                  let price  := getNatHex tx "effectiveGasPrice"
                  let value  :=
                    -- value comes as decimal wei string in this payload
                    match LeanKohaku.Encoding.Json.getField "value" tx
                      >>= LeanKohaku.Encoding.Json.asString with
                    | some s => s.toNat?.getD 0
                    | none   => 0
                  let mark :=
                    match status with
                    | "success" => "✓"
                    | "revert"  => "✗"
                    | _         => "·"
                  IO.println s!"    {mark} {txHash}"
                  IO.println s!"        status:   {status}"
                  IO.println s!"        value:    {formatEth value}"
                  IO.println s!"        block:    {block}"
                  IO.println s!"        gasUsed:  {gas}  (effectivePrice {formatGwei price})"
                  IO.println s!"        https://sepolia.etherscan.io/tx/{txHash}"
                  if status == "revert" then anyRevert := true
                -- Remaining balance for context.
                match ← DaemonClient.call "eoa.list" with
                | .ok r =>
                    let entries := (LeanKohaku.Encoding.Json.asArray r).getD #[]
                    let addr := entries.foldl (init := "") fun acc e =>
                      if !acc.isEmpty then acc
                      else
                        let n := (LeanKohaku.Encoding.Json.getField "name" e
                                  >>= LeanKohaku.Encoding.Json.asString).getD ""
                        if n = walletName then
                          (LeanKohaku.Encoding.Json.getField "address" e
                            >>= LeanKohaku.Encoding.Json.asString).getD ""
                        else acc
                    if !addr.isEmpty then
                      match ← DaemonClient.call "chain.balance"
                          (.obj #[("address", .str addr)]) with
                      | .ok b =>
                          let hex := (LeanKohaku.Encoding.Json.getField "balance" b
                                      >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
                          let wei := (hexWeiToNat hex).getD 0
                          IO.println ""
                          IO.println s!"  remaining: {formatEth wei}  ({walletName})"
                      | .error _ => pure ()
                | .error _ => pure ()
                pure (if anyRevert then 1 else 0)
  | .shieldedWithdraw toRaw amountEth =>
      let toResult ← resolveAddressOrName toRaw
      let to :=
        match toResult with
        | .ok addr => addr
        | .error _ => toRaw
      if !validAddressString to then
        IO.eprintln s!"error: '{toRaw}' is not a 0x-prefixed 20-byte address or resolvable ENS name"
        IO.eprintln ""
        IO.eprintln "Usage:"
        IO.eprintln "  kohaku unshield <recipient-address> <eth>"
        IO.eprintln ""
        IO.eprintln "Examples:"
        IO.eprintln s!"  kohaku unshield 0x551c8389508F5748Cb45e16F33cf90C14cead947 {amountEth}"
        IO.eprintln "  kohaku unshield 0xAa651C04bfE4F302eE243D6638d3B91389C4C02C 0.005"
        IO.eprintln ""
        IO.eprintln "Note: unshield takes no wallet — the relayer pays gas. Use any address you control."
        IO.eprintln "      To find your EOA address: kohaku eoa address <name>"
        return 2
      else
        let passphrase ← Passphrase.read
        match ← DaemonClient.call "shielded.unshieldDrain"
            (.obj #[
              ("recipient", .str to),
              ("amountEth", .str amountEth),
              ("passphrase", .str passphrase)
            ]) with
        | .error err =>
            IO.eprintln s!"daemon error {err.code}: {err.message}"
            pure 2
        | .ok response =>
            let resultField :=
              match LeanKohaku.Encoding.Json.getField "result" response with
              | some r => r
              | none => response
            let getHexNat (k : String) : Nat :=
              match LeanKohaku.Encoding.Json.getField k resultField >>= LeanKohaku.Encoding.Json.asString with
              | some hex => (hexWeiToNat hex).getD 0
              | none => 0
            let target := getHexNat "targetWei"
            let drained := getHexNat "drainedWei"
            let iterations := (LeanKohaku.Encoding.Json.getField "iterations" resultField >>= LeanKohaku.Encoding.Json.asNat).getD 0
            let sent := (LeanKohaku.Encoding.Json.getField "sent" resultField >>= LeanKohaku.Encoding.Json.asArray).getD #[]
            if target = 0 && drained = 0 && iterations = 0 && sent.isEmpty then
              IO.eprintln "  (parser saw empty result; raw daemon response below)"
              IO.eprintln (LeanKohaku.Encoding.Json.pretty response)
            IO.println "Unshield (Privacy Pools v1, Sepolia):"
            IO.println ""
            IO.println s!"  recipient: {to}"
            IO.println s!"  target:    {formatEth target}"
            IO.println s!"  drained:   {formatEth drained}"
            IO.println s!"  notes:     {iterations}"
            IO.println ""
            IO.println "  Transactions:"
            for entry in sent do
              let amtHex := (LeanKohaku.Encoding.Json.getField "amountWei" entry >>= LeanKohaku.Encoding.Json.asString).getD "0x0"
              let amt := (hexWeiToNat amtHex).getD 0
              let relay := (LeanKohaku.Encoding.Json.getField "relay" entry).getD (.obj #[])
              let txHash := (LeanKohaku.Encoding.Json.getField "txHash" relay >>= LeanKohaku.Encoding.Json.asString).getD "(no hash)"
              IO.println s!"    - {formatEth amt}  →  {txHash}"
              IO.println s!"        https://sepolia.etherscan.io/tx/{txHash}"
            IO.println ""
            if drained < target then
              IO.println s!"  ⚠ drained {formatEth drained} of requested {formatEth target}; remaining notes may be ASP-pending"
              pure 1
            else
              IO.println "  ✓ unshield complete"
              pure 0
  | .shieldedReveal =>
      let passphrase ← Passphrase.read "Passphrase to reveal PP secret: "
      DaemonClient.printCall "shielded.reveal"
        (.obj #[("passphrase", .str passphrase)])
  | .shieldedImport mnemonic =>
      let passphrase ← Passphrase.read
      DaemonClient.printCall "shielded.import"
        (.obj #[("passphrase", .str passphrase), ("mnemonic", .str mnemonic)])
  | .shieldedDelete =>
      let passphrase ← Passphrase.read "Passphrase to delete PP secret: "
      DaemonClient.printCall "shielded.delete"
        (.obj #[("passphrase", .str passphrase)])
  | .resolve name =>
      match ← DaemonClient.call "chain.resolveName" (.obj #[("name", .str name)]) with
      | .error err =>
          IO.eprintln s!"daemon error {err.code}: {err.message}"
          return 2
      | .ok result =>
          let addr := (LeanKohaku.Encoding.Json.getField "address" result
                       >>= LeanKohaku.Encoding.Json.asString).getD ""
          let chainId := (LeanKohaku.Encoding.Json.getField "chainId" result
                          >>= LeanKohaku.Encoding.Json.asNat).getD 0
          let chainTag :=
            if chainId = 1 then " — mainnet"
            else if chainId = 11155111 then " — sepolia"
            else ""
          IO.println s!"{name} = {addr}  (chainId={chainId}{chainTag})"
          return 0
  | .swapQuote fromTok toTok amount chain? =>
      runSwapQuote fromTok toTok amount chain?
  | .swapExec fromTok toTok amount receiver? slippage? chain? =>
      runSwapExec fromTok toTok amount receiver? slippage? chain?
  | .balances chain? address? json =>
      runBalances chain? address? json
  | .completion shell =>
      match shell with
      | "bash" => IO.println bashCompletion; return 0
      | "zsh"  => IO.println zshCompletion; return 0
      | _ =>
          IO.eprintln s!"unknown shell: {shell} (supported: bash, zsh)"
          return 2
  | .tui =>
      -- Locate the bundled TUI in this priority order:
      --   1. $LEANKOHAKU_TUI_BIN                          — explicit override
      --   2. <appDir>/../share/leankohaku/tui/index.mjs   — installed layout
      --   3. <appDir>/../../../tui/dist/index.mjs         — repo dev layout
      --        (appDir is .lake/build/bin/; repo root is three levels up)
      --   4. ./tui/dist/index.mjs (cwd)                   — last-ditch fallback
      let appDir ← IO.appDir
      let installedBundle :=
        appDir / ".." / "share" / "leankohaku" / "tui" / "index.mjs"
      let devBundle :=
        appDir / ".." / ".." / ".." / "tui" / "dist" / "index.mjs"
      let cwdBundle : System.FilePath := "tui/dist/index.mjs"
      let envBundle? ← IO.getEnv "LEANKOHAKU_TUI_BIN"
      let bundle? : Option System.FilePath ← do
        match envBundle? with
        | some p =>
            let fp : System.FilePath := p
            if ← fp.pathExists then pure (some fp) else pure none
        | none =>
            if ← installedBundle.pathExists then pure (some installedBundle)
            else if ← devBundle.pathExists then pure (some devBundle)
            else if ← cwdBundle.pathExists then pure (some cwdBundle)
            else pure none
      match bundle? with
      | none =>
          IO.eprintln "leankohaku-tui bundle not found."
          IO.eprintln ""
          IO.eprintln "Looked for it in:"
          IO.eprintln s!"  $LEANKOHAKU_TUI_BIN              ({(envBundle?.getD "<unset>")})"
          IO.eprintln s!"  {installedBundle}"
          IO.eprintln s!"  {devBundle}"
          IO.eprintln s!"  {cwdBundle}"
          IO.eprintln ""
          IO.eprintln "Build it with:  cd tui && npm install && npm run build"
          IO.eprintln "Or set LEANKOHAKU_TUI_BIN to a built dist/index.mjs."
          pure 2
      | some path =>
          -- exec node on the bundle. We use spawn+wait rather than execv
          -- so the Lean process can surface a non-zero exit code cleanly.
          try
            let child ← IO.Process.spawn
              { cmd := "node",
                args := #[path.toString],
                stdin := .inherit,
                stdout := .inherit,
                stderr := .inherit }
            let code ← child.wait
            pure (UInt32.ofNat code.toNat)
          catch e =>
            IO.eprintln s!"failed to launch leankohaku-tui ({path}): {e.toString}"
            IO.eprintln "Is `node` (≥20) installed and on PATH?"
            pure 2
  | .install    => runKohakuspawn #[]
  | .update     => runKohakuspawn #["--pull"]
  | .uninstall  => runKohakuspawn #["--uninstall"]
  | .invalid args =>
      match args with
      | "send" :: rest =>
          let got := rest.length
          -- Detect the common shell mistake: address and amount typed
          -- without a space between them, e.g. `0xABCD…1234560.01`. The
          -- glued blob arrives as a single positional argument that
          -- starts with `0x`, is longer than 42 chars, and contains a
          -- '.' past the 42-char address slot.
          let gluedHint? : Option (String × String) :=
            match rest with
            | [a] =>
                if a.startsWith "0x" && a.length > 42 then
                  let chars := a.toList
                  let addr := String.mk (chars.take 42)
                  let tail := String.mk (chars.drop 42)
                  some (addr, tail)
                else none
            | _ => none
          match gluedHint? with
          | some (addr, tail) =>
              IO.eprintln s!"error: 'send' got one glued argument — looks like the address and amount were not separated by a space"
              IO.eprintln ""
              IO.eprintln s!"  you typed:  {addr}{tail}"
              IO.eprintln s!"  parsed as:  recipient='{addr}{tail}'  (no <amount>)"
              IO.eprintln ""
              IO.eprintln "Did you mean:"
              IO.eprintln s!"  kohaku send {addr} {tail}"
          | none =>
              IO.eprintln s!"error: 'send' expects <to> <amount> (got {got} argument{if got = 1 then "" else "s"})"
          IO.eprintln ""
          IO.eprintln "Usage:"
          IO.eprintln "  kohaku send <recipient-address-or-ens> <eth> [--account <wallet>]"
          IO.eprintln ""
          IO.eprintln "Examples:"
          IO.eprintln "  kohaku send 0x551c8389508F5748Cb45e16F33cf90C14cead947 0.01"
          IO.eprintln "  kohaku send vitalik.eth 0.005"
          IO.eprintln "  kohaku send 0xAa651C04bfE4F302eE243D6638d3B91389C4C02C 0.01 --account my-eoa"
          IO.eprintln ""
          IO.eprintln "Notes:"
          IO.eprintln "  • <to> is a 0x-prefixed 20-byte address or a resolvable ENS name."
          IO.eprintln "  • <amount> is human-readable ETH (e.g. 0.01), not wei."
          IO.eprintln "  • Without --account, the wallet set via 'kohaku wallet use <name>' is used."
          return 2
      | _ =>
          IO.eprintln s!"unknown or invalid command: {args}"
          IO.println helpText
          return 2

end LeanKohaku.Cli
