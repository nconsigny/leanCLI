import LeanCli.Cli.DaemonClient
import LeanCli.Cli.Passphrase
import LeanCli.Encoding.Json
import LeanCli.Network.Endpoint
import LeanCli.Network.Provider

/-!
# CLI commands

The CLI is the primary user surface. It speaks to the daemon over the
local socket; commands that need the daemon use socket activation when present
or auto-spawn `leancli-daemon` as a local fallback.
-/

namespace LeanCli.Cli.Commands

open LeanCli.Network.Policy
open LeanCli.Network.Provider
open LeanCli.Network.Endpoint

/-! ## Input validation and local daemon preflight -/

def strip0x : String → String
  | s =>
      match s.toList with
      | '0' :: 'x' :: rest => String.ofList rest
      | '0' :: 'X' :: rest => String.ofList rest
      | _ => s

def hexDigit? (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then
    some (c.toNat - '0'.toNat)
  else if 'a' ≤ c && c ≤ 'f' then
    some (10 + c.toNat - 'a'.toNat)
  else if 'A' ≤ c && c ≤ 'F' then
    some (10 + c.toNat - 'A'.toNat)
  else
    none

def allHexChars : List Char → Bool
  | [] => true
  | c :: cs =>
      match hexDigit? c with
      | some _ => allHexChars cs
      | none => false

partial def decodeHexChars : List Char → ByteArray → Option ByteArray
  | [], acc => some acc
  | hi :: lo :: rest, acc => do
      let h ← hexDigit? hi
      let l ← hexDigit? lo
      decodeHexChars rest (acc.push (UInt8.ofNat (h * 16 + l)))
  | [_], _ => none

def decodeHex (s : String) : Option ByteArray :=
  decodeHexChars (strip0x s).toList ByteArray.empty

def hexChar (n : Nat) : Char :=
  match n with
  | 0 => '0' | 1 => '1' | 2 => '2' | 3 => '3'
  | 4 => '4' | 5 => '5' | 6 => '6' | 7 => '7'
  | 8 => '8' | 9 => '9' | 10 => 'a' | 11 => 'b'
  | 12 => 'c' | 13 => 'd' | 14 => 'e' | _ => 'f'

def encodeHex (bytes : ByteArray) : String :=
  "0x" ++ String.ofList (bytes.toList.foldr (fun b acc =>
    let n := b.toNat
    hexChar (n / 16) :: hexChar (n % 16) :: acc) [])

def byteArrayTake (bytes : ByteArray) (start len : Nat) : ByteArray :=
  (List.range len).foldl
    (init := ByteArray.empty)
    (fun acc i => acc.push bytes[start + i]!)

def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

inductive ERC20Call where
  | transfer (to : ByteArray) (amount : Nat)
  | approve (spender : ByteArray) (amount : Nat)
  | transferFrom (fromAddr to : ByteArray) (amount : Nat)
  | unknown (selector : ByteArray)

def selectorBytes (hex : String) : ByteArray :=
  (decodeHex hex).getD ByteArray.empty

def decodeAddressWord (word : ByteArray) : Option ByteArray :=
  if word.size = 32 then
    some (byteArrayTake word 12 20)
  else
    none

def decodeERC20Call (calldata : ByteArray) : Option ERC20Call :=
  if calldata.size < 4 then
    none
  else
    let selector := byteArrayTake calldata 0 4
    if selector = selectorBytes "a9059cbb" && calldata.size ≥ 68 then
      match decodeAddressWord (byteArrayTake calldata 4 32) with
      | some to => some (.transfer to (bytesToNat (byteArrayTake calldata 36 32)))
      | none => none
    else if selector = selectorBytes "095ea7b3" && calldata.size ≥ 68 then
      match decodeAddressWord (byteArrayTake calldata 4 32) with
      | some spender => some (.approve spender (bytesToNat (byteArrayTake calldata 36 32)))
      | none => none
    else if selector = selectorBytes "23b872dd" && calldata.size ≥ 100 then
      match decodeAddressWord (byteArrayTake calldata 4 32), decodeAddressWord (byteArrayTake calldata 36 32) with
      | some fromAddr, some to => some (.transferFrom fromAddr to (bytesToNat (byteArrayTake calldata 68 32)))
      | _, _ => none
    else
      some (.unknown selector)

def ERC20Call.riskLabel : ERC20Call → String
  | .transfer _ _ => "ERC20 transfer"
  | .approve _ amount =>
      if amount = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff then
        "HIGH RISK: unlimited ERC20 approval"
      else
        "ERC20 approval"
  | .transferFrom _ _ _ => "HIGH RISK: ERC20 transferFrom"
  | .unknown _ => "unknown contract call"

def validAddressString (s : String) : Bool :=
  let raw := strip0x s
  raw.toList.length = 40 && allHexChars raw.toList

def parsePositiveNat (s : String) : Option Nat :=
  match s.toNat? with
  | some n => if n > 0 then some n else none
  | none => none

theorem parsePositiveNat_some_positive {s : String} {n : Nat} :
    parsePositiveNat s = some n → n > 0 := by
  intro h
  unfold parsePositiveNat at h
  cases hs : s.toNat? with
  | none =>
      simp [hs] at h
  | some parsed =>
      by_cases hp : parsed > 0
      · simp [hs, hp] at h
        subst h
        exact hp
      · simp [hs, hp] at h

inductive Action where
  | balance (address : String)
  | send (to : String) (amountWei : Nat)
  deriving Repr, DecidableEq

def Action.valid : Action → Bool
  | .balance address => validAddressString address
  | .send to amountWei => validAddressString to && amountWei > 0

def daemonRequest (_action : Action) : NetworkRequest :=
  { peer := .localDaemon, purpose := .daemonControl, transport := .loopback }

def preflight (policy : Policy) (action : Action) : Bool :=
  action.valid && policy (daemonRequest action)

def parseBalance (address : String) : Option Action :=
  let action := Action.balance address
  if action.valid then some action else none

def parseSend (to amount : String) : Option Action := do
  let amountWei ← parsePositiveNat amount
  let action := Action.send to amountWei
  if action.valid then some action else none

def actionSummary : Action → String
  | .balance address => s!"balance address={address}"
  | .send to amountWei => s!"send to={to} amountWei={amountWei}"

structure DaemonRequest where
  action : Action
  deriving Repr, DecidableEq

inductive Plan where
  | provider (cfg : Config) (op : Operation)
  deriving Repr, DecidableEq

def providerOperation : Action → Operation
  | .balance _ => { method := .getBalance }
  | .send _ _ => { method := .sendRawTransaction }

def strictPlan (req : DaemonRequest) : Plan :=
  .provider Config.local (providerOperation req.action)

def torPlan (req : DaemonRequest) : Plan :=
  .provider Config.torConfigured (providerOperation req.action)

def planPermitted (policy : Policy) : Plan → Bool
  | .provider cfg op => permitted policy cfg op

def strictPermitted (req : DaemonRequest) : Bool :=
  planPermitted strictDaemonPolicy (strictPlan req)

def strictCliPreflight (action : Action) : Bool :=
  preflight strictCliPolicy action

def torPermitted (req : DaemonRequest) : Bool :=
  planPermitted torDaemonPolicy (torPlan req)

def planSummary : Plan → String
  | .provider cfg op =>
      let req := requestFor cfg op
      s!"backend={cfg.backend.asString} method={op.method.asString} peer={req.peer.asString} purpose={req.purpose.asString} transport={req.transport.asString}"

inductive Command where
  | help
  | version
  | policy (topic : Option String)
  | walletCreate (type : String) (name : String) (extra : Option String)
  | walletImport (name : String) (mnemonic : String) (path? : Option String)
  | walletDeploy (name : String)
  | walletList
  | walletShow (name : String)
  | walletShowAll
  | walletAddress (name : String)
  | walletAddressAll
  | walletUnlock (name : String)
  | walletUnlockAll
  | walletLock (name : String)
  | walletLockAll
  -- Wallet-level master passphrase commands. The master KEK encrypts each
  -- EOA's `masterWrap` (and the PP secret's), so one unlock covers
  -- everything not explicitly opted out via `customPassphrase`.
  | walletMasterInit (timeoutMins : Option Nat)
  | walletMasterStatus
  | walletMasterUnlock
  | walletMasterLock
  | walletMasterSetTimeout (timeoutMins : Nat)
  | walletMasterBindTpm
  | walletEnroll (name : String)
  | walletEnrollAll
  | walletDelete (name : String)
  | walletReveal (name : String)
  | walletDerive (name path : String)
  | walletSignDigest (name digest : String)
  | walletSignMessage (name message : String) (path? : Option String)
  | walletSignTx (name txJson : String) (path? : Option String)
  | walletSignTypedData (name typedDataJson : String) (path? : Option String)
  | walletHistory (name : String) (scanLogs : Bool) (allowIndexer? : Option String)
      (limit? : Option Nat) (chain? : Option String)
  | walletHistoryAll (scanLogs : Bool) (limit? : Option Nat) (chain? : Option String)
  | walletAccountAdd (name : String) (path? : Option String)
  | walletAccountList (name : String)
  | walletAccountRm (name : String) (index : String)
  | networkShow
  | networkPath
  | networkSetRpc (url : String) (transport? : Option String)
  | networkSetLightclient (url : String)
  | networkSetPolicy (policy : String)
  | networkUnsetRpc
  | networkSetEnsRpc (url : String)
  | networkUnsetEnsRpc
  | networkSetRpcChain (chain : String) (url : String) (transport? : Option String)
  | networkUnsetRpcChain (chain : String)
  | networkSetChain (chain : String)
  | networkMonitor
  | vaultStatus
  | vaultHead (chain? : Option String)
  | vaultPin (address : String) (slots : List String)
  | vaultPinAll
  | vaultRebuild (chain? : Option String)
  | vaultGet (address : String) (chain? : Option String)
  | vaultTokens (chain? : Option String)
  | doctor
  | policyCheck (policy peer purpose transport : String)
  | rpcCheck (policy backend transport method : String)
  | rpcMethods
  | endpointCheck (mode kind scheme transport credentialed : String)
  | decodeErc20 (calldata : String)
  | daemonHelp (walletName : Option String)
  | daemonPing
  | daemonVersion
  | daemonStop
  | daemonStart   -- start (systemd: `systemctl --user start`; autospawn: same as `.daemon`)
  | daemonRestart (build : Bool) -- restart; `build` rebuilds the checkout + relinks before bouncing

  | daemonStatus  -- one-line status (systemctl is-active + UDS probe)
  | daemonLogs    -- tail logs (systemd only; autospawn prints a message)
  | daemon      -- run the daemon (same as `leancli-daemon`)
  | networkAllowIndexer (name : String) (url : String)
  | networkDenyIndexer (name : String)
  | balance (address : String)
  | balanceAll
  | listAll
  | nonce (address : String)
  | tokenBalance (token owner : String)
  | gasPrice
  | priorityFee
  | estimateGas (txJson : String)
  | broadcast (rawTx : String)
  | send (to : String) (amount : String) (walletOverride? : Option String)
  | accountUse (wallet : String)
  | accountCurrent
  | accountListNames
  | accountListTypedNames
  | accountListIndices (wallet? : Option String)
  | accountListWalletIndices (withAddresses : Bool) (wallet? : Option String)
  | shieldedBalance
  | shieldedDeposit (walletName : String) (amountEth : String)
  | shieldedWithdraw (recipient amountEth : String)
  -- Tornado Cash (fixed-denomination mixer; mainnet + Sepolia). chainId is
  -- explicit because tornado, unlike Privacy Pools, is not Sepolia-pinned.
  | tornadoBalance (chainId : String)
  | tornadoDeposit (walletName : String) (chainId : String) (amountEth : String)
  | tornadoWithdraw (chainId : String) (recipient : String) (amountEth : String)
      (mode : String)
  | shieldedReveal
  | shieldedImport (mnemonic : String)
  | shieldedDelete
  | shieldedMarkDestination (address : String)
  | shieldedListDestinations
  -- SPHINCS- hybrid (ECDSA + post-quantum) ERC-4337 smart accounts. All
  -- three flows forward to a single daemon RPC each — the CLI is a
  -- printer per CLAUDE.md's thin-CLI rule.
  | sphincsCreate (name : String) (paramSet : String) (walletName : String)
      (ecdsaKind : String) (accountIndexOrPath : Option String)
      (chainOverride? : Option String) (backend? : Option String)
  | sphincsList
  | sphincsShow (name : String)
  /-- Compute the counterfactual ERC-4337 smart-account address by
      eth_call'ing the configured factory's `getAddress(...)` view.
      Updates the slot's `smartAccountAddress` field in place. -/
  | sphincsComputeAddress (name : String) (chainOverride? : Option String)
  /-- Deploy the hybrid smart account by submitting a factory.createAccount
      tx through a funded deployer EOA. -/
  | sphincsDeploy (name deployer : String) (accountIndex? : Option String)
      (chainOverride? : Option String)
  /-- Send a UserOperation from the hybrid account via the configured
      bundler. Caller supplies the target {to, value, data}; daemon
      dual-signs (ECDSA owner + SPHINCS-) and submits. -/
  | sphincsSend (name to valueWei : String) (data? : Option String)
      (chainOverride? : Option String) (backend? : Option String)
  /-- Poll the bundler for inclusion status of a previously-submitted
      UserOperation. Returns the bundler's raw payload (null when still
      pending) so the caller can inspect the receipt / block fields. -/
  | sphincsGetUserOp (userOpHash : String) (chainOverride? : Option String)
  /-- Rotate the on-chain ECDSA owner. Submits a UserOp wrapping
      `SphincsAccount.rotateOwner(newOwner)` via the existing send
      pipeline; the local store is NOT updated automatically. -/
  | sphincsRotateOwner (name newOwner : String) (chainOverride? : Option String)
  /-- Sanity-check the configured bundler — probes
      `eth_supportedEntryPoints` and reports whether the v0.9
      EntryPoint singleton is in the response. -/
  | sphincsBundlerCheck (chainOverride? : Option String)
  /-- One-shot factory deploy. Sepolia-only — refuses other chains.
      Pulls the per-paramSet verifier address from daemon.json and
      shells out to `ops/scripts/sphincs_sepolia.sh deploy`. -/
  | sphincsFactoryDeploy (paramSet deployer : String)
      (accountIndex? : Option String) (chainOverride? : Option String)
  | completion (shell : String)
  | tui
  | install
  | update
  | uninstall
  -- Phase 1c memory subcommands. All four route through the
  -- leancli-agentd UDS socket; the daemon is the sole writer of
  -- MEMORY.md.
  | memoryShow
  | memoryEdit
  | memoryRefresh (sessionId? : Option Nat)
  | memoryForget (pattern : String)
  | resolve (name : String)
  | bookList
  | bookAdd (label : String) (addrOrEns : String) (tag? : Option String)
  | bookRemove (label : String)
  | bookShow (labelOrAddr : String)
  | swapQuote (fromTok toTok amount : String) (chain? : Option String)
  | swapExec (fromTok toTok amount : String) (receiver? : Option String)
      (slippage? : Option String) (chain? : Option String)
  | balances (chain? : Option String) (address? : Option String) (json : Bool)
  | invalid (args : List String)
  deriving Repr

/-- Strip the first occurrence of `--account <n>` (or `--account=<n>`) from
    an argv list. Returns the remainder and the extracted account index string
    if present. Why: lets every existing eoa send/sign command pick up the flag
    without bloating the `Command` ADT cases. -/
def extractAccountFlag : List String → (List String × Option String)
  | [] => ([], none)
  | "--account" :: n :: rest => (rest, some n)
  | flag :: rest =>
      if flag.startsWith "--account=" then
        (rest, some (flag.drop "--account=".length).toString)
      else
        let (rest', acc?) := extractAccountFlag rest
        (flag :: rest', acc?)

/-- Split an `--account` value into an optional `<wallet>` prefix and an
    optional `<index>` portion. Accepts `bbqTest/1`, `bbqTest/`, `1`, or
    `bbqTest`. Returns `(walletPrefix?, indexStr?)`. Why: the two-stage
    completion UX uses `<wallet>/<index>`; downstream dispatch must split
    consistently and never silently drop the wallet portion. -/
def splitAccountFlag (s : String) : Option String × Option String :=
  match s.splitOn "/" with
  | [] => (none, none)
  | [only] =>
      -- Bare value: treat as the index portion when it parses as Nat,
      -- otherwise as a wallet name. Callers that only want the index can
      -- pass the original raw flag through `withOptionalAccount`.
      match only.toNat? with
      | some _ => (none, some only)
      | none => (some only, none)
  | wallet :: rest =>
      let suffix := String.intercalate "/" rest
      let idx? := if suffix.isEmpty then none else some suffix
      let w?   := if wallet.isEmpty then none else some wallet
      (w?, idx?)

/-- Strip a `--scan-logs` boolean flag. -/
def extractScanLogs : List String → (List String × Bool)
  | [] => ([], false)
  | "--scan-logs" :: rest =>
      let (rest', _) := extractScanLogs rest
      (rest', true)
  | flag :: rest =>
      let (rest', b) := extractScanLogs rest
      (flag :: rest', b)

/-- Strip a `--allow-indexer <name>` (or `--allow-indexer=<name>`) flag. -/
def extractAllowIndexer : List String → (List String × Option String)
  | [] => ([], none)
  | "--allow-indexer" :: n :: rest => (rest, some n)
  | flag :: rest =>
      if flag.startsWith "--allow-indexer=" then
        (rest, some (flag.drop "--allow-indexer=".length).toString)
      else
        let (rest', x) := extractAllowIndexer rest
        (flag :: rest', x)

/-- Strip a `--chain <name>` (or `--chain=<name>`) flag. -/
def extractChain : List String → (List String × Option String)
  | [] => ([], none)
  | "--chain" :: n :: rest => (rest, some n)
  | flag :: rest =>
      if flag.startsWith "--chain=" then
        (rest, some (flag.drop "--chain=".length).toString)
      else
        let (rest', x) := extractChain rest
        (flag :: rest', x)

/-- Strip a `--limit N` flag. Returns `none` if not present or invalid. -/
def extractLimit : List String → (List String × Option Nat)
  | [] => ([], none)
  | "--limit" :: n :: rest =>
      (rest, n.toNat?)
  | flag :: rest =>
      if flag.startsWith "--limit=" then
        (rest, (flag.drop "--limit=".length).toString.toNat?)
      else
        let (rest', x) := extractLimit rest
        (flag :: rest', x)

/-- Strip a long flag `--<name> <value>` (or `--<name>=<value>`) from anywhere
    in argv. Returns the remainder and the captured string value if present. -/
def extractStringFlag (name : String) : List String → (List String × Option String)
  | [] => ([], none)
  | flag :: v :: rest =>
      if flag = "--" ++ name then (rest, some v)
      else if flag.startsWith ("--" ++ name ++ "=") then
        (v :: rest, some (flag.drop ("--" ++ name ++ "=").length).toString)
      else
        let (rest', x) := extractStringFlag name (v :: rest)
        (flag :: rest', x)
  | [flag] =>
      if flag.startsWith ("--" ++ name ++ "=") then
        ([], some (flag.drop ("--" ++ name ++ "=").length).toString)
      else
        ([flag], none)

/-- Strip a boolean `--all` / `-a` flag from anywhere in argv. -/
def extractAllFlag : List String → (List String × Bool)
  | [] => ([], false)
  | "--all" :: rest =>
      let (rest', _) := extractAllFlag rest
      (rest', true)
  | "-a" :: rest =>
      let (rest', _) := extractAllFlag rest
      (rest', true)
  | flag :: rest =>
      let (rest', b) := extractAllFlag rest
      (flag :: rest', b)

/-- Strip a boolean `--json` flag from anywhere in argv. -/
def extractJsonFlag : List String → (List String × Bool)
  | [] => ([], false)
  | "--json" :: rest =>
      let (rest', _) := extractJsonFlag rest
      (rest', true)
  | flag :: rest =>
      let (rest', b) := extractJsonFlag rest
      (flag :: rest', b)

def parse : List String → Command
  | []                    => .help
  | ["help"]              => .help
  | ["--help"]            => .help
  | ["-h"]                => .help
  | ["version"]           => .version
  | ["--version"]         => .version
  | ["policy"]            => .policy none
  | ["policy", topic]     => .policy (some topic)
  | ["wallet", "create", typ, name] => .walletCreate typ name none
  | ["wallet", "create", typ, name, extra] => .walletCreate typ name (some extra)
  | ["wallet", "import", name, mnemonic] => .walletImport name mnemonic none
  | ["wallet", "import", name, path, mnemonic] => .walletImport name mnemonic (some path)
  | ["wallet", "deploy", name] => .walletDeploy name
  | ["wallet", "list"] => .walletList
  | ["wallet", "list", "--all"] => .walletList
  | ["wallet", "list", "-a"] => .walletList
  | ["wallet", "show", "--all"] => .walletShowAll
  | ["wallet", "show", "-a"] => .walletShowAll
  | ["wallet", "show", name] => .walletShow name
  | ["wallet", "address", "--all"] => .walletAddressAll
  | ["wallet", "address", "-a"] => .walletAddressAll
  | ["wallet", "address", name] => .walletAddress name
  | ["wallet", "unlock", "--all"] => .walletUnlockAll
  | ["wallet", "unlock", "-a"] => .walletUnlockAll
  -- `wallet unlock` (no name, no --all): master path. The CLI probes the
  -- daemon for `tpmHardwareReady`+`withTpm` and prompts for the PIN when
  -- the TPM path is available, otherwise for the passphrase — single,
  -- universal command, no mode toggle.
  | ["wallet", "unlock"] => .walletMasterUnlock
  | ["wallet", "unlock", name] => .walletUnlock name
  -- `wallet lock` (no name): clears master KEK + every per-slot unlock.
  | ["wallet", "lock"] => .walletMasterLock
  | ["wallet", "lock", "--all"] => .walletLockAll
  | ["wallet", "lock", "-a"] => .walletLockAll
  | ["wallet", "lock", name] => .walletLock name
  | ["wallet", "master", "init"] => .walletMasterInit none
  | ["wallet", "master", "init", "--timeout-mins", n] =>
      .walletMasterInit n.toNat?
  | ["wallet", "master", "status"] => .walletMasterStatus
  | ["wallet", "master", "set-timeout", n] =>
      match n.toNat? with
      | some m => .walletMasterSetTimeout m
      | none => .invalid ["wallet", "master", "set-timeout", n]
  | ["wallet", "master", "bind-tpm"] => .walletMasterBindTpm
  | ["wallet", "enroll", "--all"] => .walletEnrollAll
  | ["wallet", "enroll", "-a"] => .walletEnrollAll
  | ["wallet", "enroll", name] => .walletEnroll name
  | ["wallet", "delete", name] => .walletDelete name
  | ["wallet", "reveal", name] => .walletReveal name
  | ["wallet", "derive", name, path] => .walletDerive name path
  | ["wallet", "sign-digest", name, digest] => .walletSignDigest name digest
  | ["wallet", "sign-message", name, message] => .walletSignMessage name message none
  | ["wallet", "sign-message", name, path, message] => .walletSignMessage name message (some path)
  | ["wallet", "sign-tx", name, txJson] => .walletSignTx name txJson none
  | ["wallet", "sign-tx", name, path, txJson] => .walletSignTx name txJson (some path)
  | ["wallet", "sign-typed-data", name, json] => .walletSignTypedData name json none
  | ["wallet", "sign-typed-data", name, path, json] => .walletSignTypedData name json (some path)
  | ["wallet", "account", "list", name] => .walletAccountList name
  | ["wallet", "account", "add", name] => .walletAccountAdd name none
  | ["wallet", "account", "add", name, path] => .walletAccountAdd name (some path)
  | ["wallet", "account", "rm", name, index] => .walletAccountRm name index
  -- SPHINCS- hybrid commands. The `create` form takes:
  --   sphincs create <slotName> <paramSet> <walletName> existing [<accountIdx>] [--chain <n>] [--backend cpu|vulkan]
  --   sphincs create <slotName> <paramSet> <walletName> derived <path>          [--chain <n>] [--backend cpu|vulkan]
  -- where <paramSet> is one of C13 | SLH-DSA-SHA2-128-24
  -- (case-insensitive; short aliases c13 | slhdsa also accepted).
  -- `--backend vulkan` uses the GPU SLH-DSA signer (no-op for C13/JARDIN).
  | "sphincs" :: "create" :: rest =>
      let (rest, chain?) := extractChain rest
      let (rest, backend?) := extractStringFlag "backend" rest
      match rest with
      | [name, paramSet, walletName, "existing"] =>
          .sphincsCreate name paramSet walletName "existing" none chain? backend?
      | [name, paramSet, walletName, "existing", idx] =>
          .sphincsCreate name paramSet walletName "existing" (some idx) chain? backend?
      | [name, paramSet, walletName, "derived", path] =>
          .sphincsCreate name paramSet walletName "derived" (some path) chain? backend?
      | _ => .invalid ("sphincs" :: "create" :: rest)
  | ["sphincs", "list"] => .sphincsList
  | ["sphincs", "show", name] => .sphincsShow name
  | "sphincs" :: "compute-address" :: rest =>
      let (rest, chain?) := extractChain rest
      match rest with
      | [name] => .sphincsComputeAddress name chain?
      | _ => .invalid ("sphincs" :: "compute-address" :: rest)
  | "sphincs" :: "deploy" :: rest =>
      let (rest, chain?) := extractChain rest
      let (rest, acct?) := extractAccountFlag rest
      match rest with
      | [name, "--deployer", deployer] => .sphincsDeploy name deployer acct? chain?
      | _ => .invalid ("sphincs" :: "deploy" :: rest)
  | "sphincs" :: "send" :: rest =>
      let (rest, chain?) := extractChain rest
      let (rest, backend?) := extractStringFlag "backend" rest
      match rest with
      | [name, to, valueWei] => .sphincsSend name to valueWei none chain? backend?
      | [name, to, valueWei, "--data", data] =>
          .sphincsSend name to valueWei (some data) chain? backend?
      | _ => .invalid ("sphincs" :: "send" :: rest)
  | "sphincs" :: "get-userop" :: rest =>
      let (rest, chain?) := extractChain rest
      match rest with
      | [h] => .sphincsGetUserOp h chain?
      | _ => .invalid ("sphincs" :: "get-userop" :: rest)
  | "sphincs" :: "rotate-owner" :: rest =>
      let (rest, chain?) := extractChain rest
      match rest with
      | [name, newOwner] => .sphincsRotateOwner name newOwner chain?
      | _ => .invalid ("sphincs" :: "rotate-owner" :: rest)
  | "sphincs" :: "check-bundler" :: rest =>
      let (rest, chain?) := extractChain rest
      match rest with
      | [] => .sphincsBundlerCheck chain?
      | _ => .invalid ("sphincs" :: "check-bundler" :: rest)
  | "sphincs" :: "factory-deploy" :: rest =>
      let (rest, chain?) := extractChain rest
      let (rest, acct?) := extractAccountFlag rest
      match rest with
      | [paramSet, "--deployer", deployer] =>
          .sphincsFactoryDeploy paramSet deployer acct? chain?
      | _ => .invalid ("sphincs" :: "factory-deploy" :: rest)
  | "wallet" :: "history" :: rest =>
      let (rest, allFlag) := extractAllFlag rest
      let (rest, scanLogs) := extractScanLogs rest
      let (rest, indexer?) := extractAllowIndexer rest
      let (rest, chain?) := extractChain rest
      let (rest, limit?) := extractLimit rest
      if allFlag then
        .walletHistoryAll scanLogs limit? chain?
      else
        match rest with
        | [name] => .walletHistory name scanLogs indexer? limit? chain?
        | _ => .invalid ("wallet" :: "history" :: rest)
  | ["network"]                            => .networkShow
  | ["network", "show"]                    => .networkShow
  | ["network", "path"]                    => .networkPath
  | ["network", "set-rpc", url]            => .networkSetRpc url none
  | ["network", "set-rpc", url, transport] => .networkSetRpc url (some transport)
  | ["network", "set-lightclient", url]    => .networkSetLightclient url
  | ["network", "set-policy", policy]      => .networkSetPolicy policy
  | ["network", "unset-rpc"]               => .networkUnsetRpc
  | ["network", "set-ens-rpc", url]        => .networkSetEnsRpc url
  | ["network", "unset-ens-rpc"]           => .networkUnsetEnsRpc
  | ["network", "set-rpc-chain", chain, url]            => .networkSetRpcChain chain url none
  | ["network", "set-rpc-chain", chain, url, transport] => .networkSetRpcChain chain url (some transport)
  | ["network", "unset-rpc-chain", chain]               => .networkUnsetRpcChain chain
  | ["network", "set-chain", chain]                     => .networkSetChain chain
  | ["network", "monitor"]                 => .networkMonitor
  | ["vault"]                              => .vaultStatus
  | ["vault", "status"]                    => .vaultStatus
  | ["vault", "head"]                      => .vaultHead none
  | ["vault", "head", chain]               => .vaultHead (some chain)
  | ["vault", "get", addr]                 => .vaultGet addr none
  | ["vault", "get", addr, chain]          => .vaultGet addr (some chain)
  | ["vault", "tokens"]                    => .vaultTokens none
  | ["vault", "tokens", chain]             => .vaultTokens (some chain)
  | ["vault", "pin"]                       => .vaultPinAll
  | ["vault", "rebuild"]                   => .vaultRebuild none
  | ["vault", "rebuild", chain]            => .vaultRebuild (some chain)
  | "vault" :: "pin" :: addr :: rest       => .vaultPin addr rest
  | ["doctor"]            => .doctor
  | ["daemon", "help"] => .daemonHelp none
  | ["daemon", "ping"] => .daemonPing
  | ["daemon", "version"] => .daemonVersion
  | ["daemon", "stop"] => .daemonStop
  | ["daemon", "start"] => .daemonStart
  | ["daemon", "restart"] => .daemonRestart true
  | ["daemon", "restart", "--no-build"] => .daemonRestart false
  | ["daemon", "restart", "--quick"] => .daemonRestart false
  | ["daemon", "status"] => .daemonStatus
  | ["daemon", "logs"] => .daemonLogs
  | ["daemon", walletName, "help"] => .daemonHelp (some walletName)
  | ["daemon"]            => .daemon
  | ["network", "allow-indexer", "etherscan"] =>
      .networkAllowIndexer "etherscan" "https://api.etherscan.io/v2/api"
  | ["network", "allow-indexer", name] =>
      .networkAllowIndexer name ""
  | ["network", "allow-indexer", name, url] =>
      .networkAllowIndexer name url
  | ["network", "deny-indexer", name] => .networkDenyIndexer name
  | ["balance"]           => .balanceAll
  | ["balance", "-a"]     => .balanceAll
  | ["balance", "--all"]  => .balanceAll
  | ["list"]              => .listAll
  | ["list", "-a"]        => .listAll
  | ["list", "--all"]     => .listAll
  | ["balance", addr]     => .balance addr
  -- chain namespace (advanced reads + raw broadcast)
  | ["chain", "balance", addr] => .balance addr
  | ["chain", "nonce", addr] => .nonce addr
  | ["chain", "token-balance", token, owner] => .tokenBalance token owner
  | ["chain", "gas-price"] => .gasPrice
  | ["chain", "priority-fee"] => .priorityFee
  | ["chain", "estimate-gas", txJson] => .estimateGas txJson
  | ["chain", "broadcast", rawTx] => .broadcast rawTx
  -- debug namespace (policy/RPC simulation, ABI decode)
  | ["debug", "policy-check", policy, peer, purpose, transport] =>
      .policyCheck policy peer purpose transport
  | ["debug", "rpc-check", policy, backend, transport, method] =>
      .rpcCheck policy backend transport method
  | ["debug", "rpc-methods"] => .rpcMethods
  | ["debug", "endpoint-check", mode, kind, scheme, transport, credentialed] =>
      .endpointCheck mode kind scheme transport credentialed
  | ["debug", "decode", "erc20", calldata] => .decodeErc20 calldata
  | ["send", to, amount]  => .send to amount none
  | ["from", wallet, "send", to, amount] => .send to amount (some wallet)
  | ["wallet", "use", wallet] => .accountUse wallet
  | ["wallet", "current"] => .accountCurrent
  | ["wallet", "list-names"] => .accountListNames
  | ["wallet", "list-typed-names"] => .accountListTypedNames
  | ["wallet", "list-indices"] => .accountListIndices none
  | ["wallet", "list-indices", wallet] => .accountListIndices (some wallet)
  | ["wallet", "list-walletindices"] => .accountListWalletIndices false none
  | ["wallet", "list-walletindices", "--addresses"] => .accountListWalletIndices true none
  | ["wallet", "list-walletindices", w] => .accountListWalletIndices false (some w)
  | ["wallet", "list-walletindices", "--addresses", w] => .accountListWalletIndices true (some w)
  | ["wallet", "list-walletindices", w, "--addresses"] => .accountListWalletIndices true (some w)
  | ["shield", "balance"] => .shieldedBalance
  | ["shield", "reveal"] => .shieldedReveal
  | ["shield", "delete"] => .shieldedDelete
  | ["shield", "import", mnemonic] => .shieldedImport mnemonic
  | ["shield", "mark-destination", address] => .shieldedMarkDestination address
  | ["shield", "list-destinations"] => .shieldedListDestinations
  -- Tornado subcommands must precede the generic `shield <wallet> <amount>`
  -- so "tornado" isn't parsed as a wallet name.
  | ["shield", "tornado", "balance", chainId] => .tornadoBalance chainId
  | ["shield", "tornado", walletName, chainId, amountEth] =>
      .tornadoDeposit walletName chainId amountEth
  | ["unshield", "tornado", chainId, to, amountEth] =>
      .tornadoWithdraw chainId to amountEth "paymaster"
  | ["unshield", "tornado", chainId, to, amountEth, mode] =>
      .tornadoWithdraw chainId to amountEth mode
  | ["shield", walletName, amountEth] => .shieldedDeposit walletName amountEth
  | ["unshield", to, amountEth] => .shieldedWithdraw to amountEth
  | "swap" :: "quote" :: rest =>
      let (rest, fromTok?) := extractStringFlag "from" rest
      let (rest, toTok?) := extractStringFlag "to" rest
      let (rest, amount?) := extractStringFlag "amount" rest
      let (rest, chain?) := extractChain rest
      match fromTok?, toTok?, amount?, rest with
      | some f, some t, some a, [] => .swapQuote f t a chain?
      | _, _, _, _ => .invalid ("swap" :: "quote" :: rest)
  | "swap" :: "exec" :: rest =>
      let (rest, fromTok?) := extractStringFlag "from" rest
      let (rest, toTok?) := extractStringFlag "to" rest
      let (rest, amount?) := extractStringFlag "amount" rest
      let (rest, receiver?) := extractStringFlag "receiver" rest
      let (rest, slippage?) := extractStringFlag "slippage" rest
      let (rest, chain?) := extractChain rest
      match fromTok?, toTok?, amount?, rest with
      | some f, some t, some a, [] => .swapExec f t a receiver? slippage? chain?
      | _, _, _, _ => .invalid ("swap" :: "exec" :: rest)
  | "balances" :: rest =>
      -- `leancli balances [--chain mainnet|sepolia] [--address 0x...] [--json]`
      -- Print one row per registry token (filtered by chain) plus an ETH
      -- synthetic row. Defaults: chain = daemon's current chain;
      -- address = active EOA's default account.
      let (rest, chain?) := extractChain rest
      let (rest, address?) := extractStringFlag "address" rest
      let (rest, json) := extractJsonFlag rest
      match rest with
      | [] => .balances chain? address? json
      | _  => .invalid ("balances" :: rest)
  | ["completion", shell]  => .completion shell
  | ["tui"]                => .tui
  | ["ui"]                 => .tui
  | ["install"]            => .install
  | ["update"]             => .update
  | ["uninstall"]          => .uninstall
  | ["resolve", name]      => .resolve name
  | ["book"]                       => .bookList
  | ["book", "list"]               => .bookList
  | ["book", "add", label, addr]   => .bookAdd label addr none
  | ["book", "add", label, addr, "--tag", tag] => .bookAdd label addr (some tag)
  | ["book", "remove", label]      => .bookRemove label
  | ["book", "rm", label]          => .bookRemove label
  | ["book", "show", needle]       => .bookShow needle
  | ["memory"]                              => .memoryShow
  | ["memory", "show"]                      => .memoryShow
  | ["memory", "edit"]                      => .memoryEdit
  | ["memory", "refresh"]                   => .memoryRefresh none
  | ["memory", "refresh", "--session", n]   =>
      match n.toNat? with
      | some k => .memoryRefresh (some k)
      | none   => .invalid ["memory", "refresh", "--session", n]
  | ["memory", "forget", pattern]           => .memoryForget pattern
  | args                  => .invalid args

/-- Parse argv, also returning an optional `--account <n>` index that got
    stripped before pattern matching. -/
def parseTop (args : List String) : Command × Option String :=
  let (rest, acc?) := extractAccountFlag args
  (parse rest, acc?)

private def joinComma : List String → String
  | [] => ""
  | [x] => x
  | x :: xs => x ++ ", " ++ joinComma xs

private def allowDeny (b : Bool) : String :=
  if b then "ALLOW" else "DENY"

def policyCheckText (policyS peerS purposeS transportS : String) : String :=
  match parsePolicy policyS, parsePeer peerS, parsePurpose purposeS, parseTransport transportS with
  | some policy, some peer, some purpose, some transport =>
      let req : NetworkRequest := { peer, purpose, transport }
      s!"{allowDeny (policy req)} policy={policyS} peer={peer.asString} purpose={purpose.asString} transport={transport.asString}"
  | _, _, _, _ =>
      "invalid policy-check arguments\n\n\
       usage: leancli policy-check <policy> <peer> <purpose> <transport>\n\
       policies: " ++ joinComma policyNames ++ "\n\
       peers: " ++ joinComma peerNames ++ "\n\
       purposes: " ++ joinComma purposeNames ++ "\n\
       transports: " ++ joinComma transportNames

def rpcCheckText (policyS backendS transportS methodS : String) : String :=
  match parsePolicy policyS, parseBackend backendS, parseTransport transportS, parseRpcMethod methodS with
  | some policy, some backend, some transport, some method =>
      let cfg : Config := { backend, transport }
      let op : Operation := { method }
      let req := requestFor cfg op
      s!"{allowDeny (permitted policy cfg op)} policy={policyS} backend={backend.asString} method={method.asString} peer={req.peer.asString} purpose={req.purpose.asString} transport={req.transport.asString}"
  | _, _, _, _ =>
      "invalid rpc-check arguments\n\n\
       usage: leancli rpc-check <policy> <backend> <transport> <rpc-method>\n\
       policies: " ++ joinComma policyNames ++ "\n\
       backends: " ++ joinComma backendNames ++ "\n\
       transports: " ++ joinComma transportNames ++ "\n\
       methods: " ++ joinComma rpcMethodNames

def endpointCheckText (modeS kindS schemeS transportS credentialedS : String) : String :=
  match parseEndpointKind kindS, parseScheme schemeS, parseTransport transportS, parseBool credentialedS with
  | some kind, some scheme, some transport, some credentialed =>
      let ep : Endpoint := { kind, scheme, transport, credentialed }
      let allowed :=
        match modeS with
        | "strict" => acceptedStrict ep
        | "tor" => acceptedTor ep
        | _ => false
      s!"{allowDeny allowed} mode={modeS} endpoint-kind={kind.asString} scheme={scheme.asString} transport={transport.asString} credentialed={credentialed}"
  | _, _, _, _ =>
      "invalid endpoint-check arguments\n\n\
       usage: leancli endpoint-check <strict|tor> <kind> <scheme> <transport> <credentialed>\n\
       kinds: " ++ joinComma kindNames ++ "\n\
       schemes: " ++ joinComma schemeNames ++ "\n\
       transports: " ++ joinComma transportNames ++ "\n\
       credentialed: true, false"

def privacyText : String :=
  "leanCLI privacy policy\n\n\
   CLI:\n\
     - only local daemon control over loopback is allowed\n\
     - direct node, indexer, analytics, price, fiat, metadata, discovery, and crash-report calls are denied\n\n\
   Daemon:\n\
     - local/light-client reads use loopback\n\
     - local transaction broadcast uses loopback\n\
     - configured-node traffic is denied in strict mode\n\
     - Tor mode may read or broadcast through a configured node over Tor\n\
     - third-party APIs remain denied even when Tor is enabled\n\n\
   Policy modules: LeanCli.Network.Policy, LeanCli.Network.Provider.\n"

def networkText : String :=
  "leanCLI network surface\n\n\
   Allowed JSON-RPC purposes:\n\
     - nodeRead: chain id, block number, balance, nonce, code, call, gas estimation, fee data\n\
     - broadcastTx: eth_sendRawTransaction only\n\n\
   Denied surfaces:\n\
     - peer discovery\n\
     - analytics and telemetry\n\
     - price quotes and fiat onramps\n\
     - metadata lookups and indexer APIs\n\
     - crash-report uploads\n\
     - any unclassified transport path\n"

def securityText : String :=
  "leanCLI security posture\n\n\
   Hard rules:\n\
     - deny by default\n\
     - CLI never talks to nodes or third-party services\n\
     - strict daemon mode is local/light-client only\n\
     - configured-node access requires Tor mode\n\
     - only eth_sendRawTransaction is a broadcast purpose\n\
     - no analytics, telemetry, price APIs, fiat/onramp APIs, indexers, metadata lookup, peer discovery, or crash uploads\n\n\
   Useful checks:\n\
     leancli policy-check strict configured-node broadcast-tx direct\n\
     leancli policy-check tor configured-node node-read tor\n\
     leancli rpc-check strict configured direct eth_getBalance\n\
     leancli rpc-check tor configured tor eth_sendRawTransaction\n\
     leancli endpoint-check strict local http loopback false\n\
     leancli endpoint-check tor configured onion tor false\n"

def rpcMethodsText : String :=
  "allowed modeled JSON-RPC methods:\n" ++ joinComma rpcMethodNames

def erc20DecodeText (calldataHex : String) : String :=
  match decodeHex calldataHex with
  | none => "invalid hex calldata"
  | some calldata =>
      match decodeERC20Call calldata with
      | none => "not enough calldata for an ERC-20 selector"
      | some call =>
          match call with
          | .transfer to amount =>
              "ERC20 transfer\n" ++
              "risk: " ++ call.riskLabel ++ "\n" ++
              "to: " ++ encodeHex to ++ "\n" ++
              "amount: " ++ toString amount
          | .approve spender amount =>
              "ERC20 approve\n" ++
              "risk: " ++ call.riskLabel ++ "\n" ++
              "spender: " ++ encodeHex spender ++ "\n" ++
              "amount: " ++ toString amount
          | .transferFrom fromAddr to amount =>
              "ERC20 transferFrom\n" ++
              "risk: " ++ call.riskLabel ++ "\n" ++
              "from: " ++ encodeHex fromAddr ++ "\n" ++
              "to: " ++ encodeHex to ++ "\n" ++
              "amount: " ++ toString amount
          | .unknown selector =>
              "unknown contract call\nselector: " ++ encodeHex selector

def doctorText : String :=
  "leanCLI doctor\n\n\
   Privacy/security status:\n\
     - CLI local-daemon boundary: modeled and proved\n\
     - strict daemon local-only provider policy: modeled and proved\n\
     - Tor configured-node mode: modeled and proved\n\
     - third-party/API-key endpoint denial: modeled and proved\n\
     - chain reads and raw broadcast: daemon-mediated and policy-gated\n\
     - daemon transport: Unix-domain socket with same-uid peer check\n\
     - EOA signing: daemon-only; CLI forwards JSON-RPC requests\n\n\
   Run checks:\n\
     lake build\n\
     ./ops/scripts/check_privacy_cli.sh\n"

def daemonHelpText (walletName? : Option String) : String :=
  let walletName := walletName?.getD "<wallet>"
  "leanCLI daemon commands\n\n\
   Lifecycle (systemd-aware when ~/.config/leancli/managed-by-systemd is present;\n\
   otherwise autospawn — the next CLI request brings the daemon up on demand):\n\
     leancli daemon                   Start the daemon (foreground or via systemd).\n\
     leancli daemon start             Same as above; explicit form.\n\
     leancli daemon stop              Stop the daemon (RPC shutdown or systemctl).\n\
     leancli daemon restart           Rebuild this checkout (lake build) + relink + bounce.\n\
     leancli daemon restart --no-build  Just bounce the running daemon (fast; no rebuild).\n\
     leancli daemon ping              JSON-RPC ping over the UDS.\n\
     leancli daemon status            One-line is-active + UDS-probe summary.\n\
     leancli daemon logs              Tail the journal (systemd install only).\n\
     leancli daemon version           Print the running daemon's build version.\n\n\
   Primary wallet send shape:\n\
     leancli daemon <wallet> send <chain> <to> <eth>\n\n\
   Example:\n\
     leancli daemon " ++ walletName ++ " send sepolia 0xAa651C04bfE4F302eE243D6638d3B91389C4C02C 0.002\n\n\
   Arguments:\n\
     <wallet>  Local EOA wallet slot name, for example daily or sepolia\n\
     <chain>   sepolia today; mainnet is dev-gated\n\
     <to>      20-byte Ethereum address, 0x-prefixed\n\
     <eth>     Human ETH amount, for example 0, 0.001, or 0.002\n\n\
   What happens on send:\n\
     1. Decode the intent and simulate it (decode → simulate)\n\
     2. Convert ETH to wei locally\n\
     3. Show the intent + simulation outcome for confirmation (ConfirmGate)\n\
     4. Sign with the in-process secp256k1 EOA key and broadcast\n\n\
   Setup commands:\n\
     leancli wallet create eoa " ++ walletName ++ "\n\n\
   Inspect:\n\
     leancli wallet list\n\n\
   Safety notes:\n\
     - The encrypted seed stays local under .leancli/ and is gitignored\n\
     - Every send flows through decode → simulate → ConfirmGate before signing\n"

def lightclientText : String :=
  "leanCLI provider policy plan\n\n\
   Provider model:\n\
     - represents provider operations as Lean data before transport exists\n\
     - classifies methods by peer, purpose, and transport\n\
     - treats local node and future light-client reads as local policy paths\n\
     - separates transaction broadcast from read-only chain queries\n\n\
   Privacy constraints:\n\
     - no third-party APIs for discovery, metadata, analytics, or prices\n\
     - no direct CLI node calls; the daemon owns provider access\n\
     - Tor mode may read and broadcast through a configured node over Tor\n\
     - configured-node access requires explicit Tor policy\n\n\
   See LeanCli.Network.Provider and LeanCli.Invariants.Network.\n"

def keystoreText : String :=
  "leanCLI local keystore policy\n\n\
   Boundary:\n\
     - keystore access is local-only; no online or remote keystore service\n\
     - wallet code must never receive raw private keys or seed material\n\
     - normal operations deny key import/export\n\
     - signing requires hardware-backed key custody and user authorization\n\n\
   Platform notes:\n\
     - Ethereum mainnet is production; Sepolia is explicit dev/testnet support\n\
     - the generic P-256 hardware capability table models which local\n\
       backends (TPM2 / FIDO2 / Secure Enclave) can hold and sign with a\n\
       non-exportable key; no on-chain P-256/R1 account path consumes it today\n\
     - Linux profiles prefer TPM2 on common HP/Lenovo hardware, with FIDO2 fallback\n\
     - the Linux kernel keyring is modeled as local handle storage, not signing\n\n\
   Runtime:\n\
     - the TPM-sealed master KEK (wallet master) seals the wallet's key-\n\
       encryption key behind a TPM auth-value PIN\n\
     - PIN attempts are rate-limited by the TPM's dictionary-attack lockout\n\
     - key material is stored under .leancli/ and is ignored by git\n\n\
   See LeanCli.Keystore.Enclave, LeanCli.Keystore.Linux, and\n\
   LeanCli.Keystore.Tpm2Runtime.\n"

def accountsText : String :=
  "leanCLI account policy\n\n\
   Supported account families:\n\
     - eoa-k1: regular BIP-39/BIP-32 Ethereum EOA with k1 signing\n\
     - sphincs-hybrid: ERC-4337 smart account gated on a stored ECDSA owner\n\
       AND a stateless SPHINCS+ post-quantum verifier\n\n\
   Defaults:\n\
     - eoa-k1 path: m/44'/60'/0'/0/0\n\
     - chain: Ethereum mainnet by default; Sepolia is available for dev/testing\n\
     - custody: local only; no online keystore\n\n\
   See LeanCli.Wallet.Account and LeanCli.Invariants.Account.\n"

def policyTopicNames : List String :=
  ["accounts", "keystore", "lightclient", "network", "privacy", "security"]

def policyOverviewText : String :=
  "leanCLI policy reference\n\n\
   Topics:\n\
     accounts     — supported account families and defaults\n\
     keystore     — local keystore custody policy\n\
     lightclient  — provider-policy plan and privacy constraints\n\
     network      — allowed JSON-RPC purposes and denied surfaces\n\
     privacy      — network privacy policy summary\n\
     security     — hard rules and useful checks\n\n\
   Run `leancli policy <topic>` for detail. Run `leancli policy all` for everything.\n"

def policyAllText : String :=
  "=== ACCOUNTS ===\n\n" ++ accountsText ++
  "\n=== KEYSTORE ===\n\n" ++ keystoreText ++
  "\n=== LIGHTCLIENT ===\n\n" ++ lightclientText ++
  "\n=== NETWORK ===\n\n" ++ networkText ++
  "\n=== PRIVACY ===\n\n" ++ privacyText ++
  "\n=== SECURITY ===\n\n" ++ securityText

def policyText (topic : Option String) : String :=
  match topic with
  | none => policyOverviewText
  | some "all" => policyAllText
  | some "accounts" => accountsText
  | some "keystore" => keystoreText
  | some "lightclient" => lightclientText
  | some "network" => networkText
  | some "privacy" => privacyText
  | some "security" => securityText
  | some t =>
      s!"unknown policy topic: {t}\n\n" ++ policyOverviewText

def helpText : String :=
  "leancli — formally-verified Ethereum wallet (Lean 4)\n\n\
   USAGE:\n\
     leancli <command> [args]\n\n\
   MAIN COMMANDS:\n\
     send <to> <amount> [--account <wallet>]\n\
                                         Send ETH from the default wallet (set via 'wallet use').\n\
                                         <to> is 0x... or ENS. <amount> is human ETH.\n\
     from <wallet> send <to> <amount>    Send ETH from a specific wallet,\n\
                                         bypassing the default. Tab-completes <wallet>.\n\
     balance | balance -a                Sum balances across all wallets (Sepolia).\n\
                                         With -a also adds shielded (Privacy-Pools) totals.\n\
     balance <address>                   Read ETH balance of one address.\n\
     balances [--chain <c>] [--address 0x..] [--json]\n\
                                         Per-token balances (registry + ETH) for one address.\n\
                                         Defaults: current chain, default account.\n\
     list | list -a                      Tree view of wallets.\n\
     wallet use <wallet>                 Set default wallet for `send`.\n\
     wallet current                      Print current default wallet.\n\
     resolve <name>                      Resolve an ENS name to an address.\n\
     book                                List address-book entries.\n\
     book add <label> <addr|name.eth>    Add or replace an entry; .eth names are resolved first.\n\
     book remove <label>                 Remove an entry by label.\n\
     book show <label-or-0x>             Look up by label or address.\n\
     tui | ui                            Open the interactive Ink-based UI\n\
                                         (arrow-key navigation, requires Node ≥20).\n\
     install                             Rebuild + relink ~/.leancli/bin/{leancli,leancli-daemon}\n\
                                         (delegates to ops/scripts/leanclispawn).\n\
     update                              git pull + rebuild + relink (leanclispawn --pull).\n\
     uninstall                           Remove ~/.leancli/bin symlinks (leanclispawn --uninstall).\n\n\
   SETUP / WALLET MANAGEMENT:\n\
     wallet create eoa <name> [path]     Create an encrypted EOA slot.\n\
     wallet import <name> [path] <words> Import a BIP-39 mnemonic as an EOA slot.\n\
     wallet list                         Tabular list of every wallet.\n\
     wallet show <name>                  Wallet metadata.\n\
     wallet address <name>               Primary address.\n\
     wallet unlock <name>                Per-slot EOA passphrase prompt.\n\
     wallet unlock                       Master unlock — single prompt; TPM-PIN if hardware present,\n\
                                         master passphrase otherwise. Covers every enrolled EOA + PP secret.\n\
     wallet lock <name>                  Lock one wallet.\n\
     wallet lock                         Clear the master KEK and every per-slot unlock in one shot.\n\
     wallet master init [--timeout-mins N]\n\
                                         Bootstrap the wallet KEK manifest. Prompts for a master passphrase;\n\
                                         if a TPM is detected, also offers an optional PIN to seal the KEK\n\
                                         under the TPM (skip with Enter). --timeout-mins N sets auto-lock\n\
                                         (0 disables; default 5).\n\
     wallet master status                Show master-init state, enrolled vs. unenrolled EOAs, TPM availability.\n\
     wallet master set-timeout N         Update auto-lock minutes (0 = never).\n\
     wallet master bind-tpm              Add TPM-PIN unlock to an existing wallet master (post-init).\n\
                                         BIP-39 EOA seeds enrolled via `wallet enroll` then inherit TPM-tier\n\
                                         lockout protection (PIN attempts rate-limited by TPM firmware).\n\
     wallet enroll <name>                Enrol one EOA into the master KEK (lazy rewrap on next unlock).\n\
     wallet enroll --all                 Walk every unenrolled EOA and enrol each.\n\
     wallet delete <name>                Delete a wallet (passphrase required for EOA).\n\
     wallet reveal <name>                Print the BIP-39 mnemonic of an EOA (DANGER).\n\
                                         Requires passphrase + name confirmation.\n\
                                         Only works for slots created with mnemonic retention.\n\
     wallet derive <name> <path>         Derive an extra path (EOA only).\n\
     wallet sign-digest <name> <hash>    Sign a 32-byte digest.\n\
     wallet sign-message <name> [path] <msg>\n\
                                         Personal-message sign.\n\
     wallet sign-tx <name> [path] <tx-json>\n\
                                         Sign a transaction.\n\
     wallet sign-typed-data <name> [path] <json>\n\
                                         EIP-712 sign.\n\
     wallet history <name> [--scan-logs] [--limit N]\n\
                                         Local journal + optional log scan.\n\
     wallet account list <name>          List sub-accounts on an EOA slot.\n\
     wallet account add <name> [path]    Derive a new sub-account (EOA only).\n\
     wallet account rm <name> <index>    Remove a sub-account by index (EOA only).\n\n\
   PRIVACY:\n\
     shield <wallet> <eth>               Privacy-Pools v1 deposit.\n\
     shield balance                      Show shielded balance.\n\
     shield reveal                       Print the stored PP mnemonic once.\n\
     shield import <mnemonic>            Store a user-supplied PP mnemonic.\n\
     shield delete                       WARNING: removes the stored PP secret.\n\
     shield mark-destination <addr>      Backfill the PP-funded log (manual attestation).\n\
     shield list-destinations            Print every recorded PP-funded recipient.\n\
     unshield <to> <eth>                 Privacy-Pools withdrawal via the relayer.\n\n\
   CHAIN UTILITIES (advanced):\n\
     chain balance <addr> | nonce <addr> | gas-price | priority-fee\n\
     chain token-balance <token> <owner>\n\
     chain estimate-gas <tx-json> | broadcast <raw-tx>\n\n\
   NETWORK CONFIG:\n\
     network show | network path\n\
     network set-rpc <url> [transport]\n\
     network set-lightclient <url>\n\
     network set-policy <strict|tor|permissive>\n\
     network unset-rpc\n\
     network set-ens-rpc <url> | network unset-ens-rpc\n\
     network set-rpc-chain <chain> <url> [transport]\n\
     network unset-rpc-chain <chain>\n\
     network set-chain <chain>          Set the daemon's default chain (name or numeric id).\n\
     network monitor\n\n\
   STATE VAULT (partial state node):\n\
     vault [status]                      Row counts + DB path of the local state vault.\n\
     vault head [chain]                  Pin the current verified head (block + stateRoot).\n\
     vault pin [addr] [slot ...]         Prove account (+ slots) via eth_getProof, verified\n\
                                         in Lean against the pinned state root; store at\n\
                                         that exact block (tier: lean). With no address,\n\
                                         pins EVERY wallet-owned account.\n\
     vault rebuild [chain]               Restore-from-seed helper: pin owned accounts, then\n\
                                         rediscover the touched-token set from the wallet's\n\
                                         own on-chain log footprint (newest-first, resumable).\n\
     vault get <addr> [chain]            Serve stored state, explicitly \"as of block N\".\n\
     vault tokens [chain]                Stored token metadata + provenance tier.\n\n\
   DAEMON / DOCS:\n\
     daemon                              Start the daemon (foreground or via systemd).\n\
     daemon start | stop | restart       Lifecycle control (systemd-aware when installed).\n\
     daemon ping | status | version      Health probe, one-line status, build version.\n\
     daemon logs                         Tail journal (systemd install only).\n\
     policy [accounts|keystore|lightclient|network|privacy|security|all]\n\
                                         Show internal policy reference\n\
     doctor                              Implementation/check status\n\n\
   DEBUG / SIMULATION:\n\
     debug rpc-methods\n\
     debug policy-check <policy> <peer> <purpose> <transport>\n\
     debug rpc-check <policy> <backend> <transport> <method>\n\
     debug endpoint-check <mode> <kind> <scheme> <transport> <credentialed>\n\
     debug decode erc20 <calldata>\n\n\
   SHELL COMPLETION (install once):\n\
     completion bash | completion zsh | completion fish    Print a completion script\n\
     # bash:\n\
     #   leancli completion bash > ~/.local/share/bash-completion/completions/leancli\n\
     # zsh (after `autoload -U bashcompinit && bashcompinit`):\n\
     #   leancli completion zsh > \"${fpath[1]}/_leancli\"\n\
     # fish (no rc edits needed; fish autoloads from this dir):\n\
     #   leancli completion fish > ~/.config/fish/completions/leancli.fish\n"

def bashCompletion : String :=
  String.intercalate "\n" [
    "# leancli / leancli bash completion",
    "_leancli_complete() {",
    "  local cur",
    "  cur=\"${COMP_WORDS[COMP_CWORD]}\"",
    "  local top=\"help version policy network doctor wallet shield unshield daemon balance balances list send from chain debug resolve tui ui install update uninstall\"",
    "  # If we're completing the value after --account, decide whether the value",
    "  # is a wallet name (e.g. for `daemon <wallet> send`) or a sub-account index",
    "  # (e.g. for `send` and `eoa send|sign-*|send-wei`).",
    "  # Hint helper: display placeholder label(s) for a free-form positional",
    "  # slot (address, amount, ENS name, hex digest…). Forces ≥2 entries when",
    "  # cur is empty so bash lists them without auto-inserting any. Filters",
    "  # by cur prefix once the user starts typing — hints disappear, real",
    "  # input takes over. Disables filename fallback so we don't suggest",
    "  # files for a wei amount.",
    "  _leancli_hint() {",
    "    # Display placeholder hint(s) without auto-insertion. Bash inserts the",
    "    # longest common prefix when multiple candidates share one, so we",
    "    # decorate each hint with a distinct leading marker so no common",
    "    # prefix exists. Result: hints render as a menu, nothing is typed for",
    "    # the user.",
    "    local _c=\"$1\"; shift",
    "    local _h _list=\"\" _i=0",
    "    local _markers=(\"« \" \"» \" \"– \" \"· \")",
    "    for _h in \"$@\"; do",
    "      local _m=\"${_markers[$_i]:-· }\"",
    "      _list+=\"${_m}${_h} \"",
    "      _i=$((_i+1))",
    "    done",
    "    COMPREPLY=( $(compgen -W \"$_list\" -- \"$_c\") )",
    "    if [ \"${#COMPREPLY[@]}\" -eq 1 ] && [ -z \"$_c\" ]; then",
    "      COMPREPLY+=(\"· then-type-the-value\")",
    "    fi",
    "    compopt +o default 2>/dev/null",
    "  }",
    "  _leancli_account_value() {",
    "    # $1 = current word being completed",
    "    local _cur=\"$1\"",
    "    local _sub=\"\" _is_index=0",
    "    # Index-mode commands: --account <wallet>/<idx>. Otherwise: wallet name only.",
    "    if [ \"${COMP_WORDS[1]}\" = \"send\" ]; then",
    "      _is_index=1",
    "    fi",
    "    if [ \"$_is_index\" = \"1\" ]; then",
    "      # EOA wallets get `<wallet>/<index>` (sub-account form). Wallet type",
    "      # is read from `wallet list-typed-names` which emits `<type>\\t<name>`.",
    "      case \"$_cur\" in",
    "        */*)",
    "          local _w=\"${_cur%%/*}\"",
    "          local _suffix=\"${_cur#*/}\"",
    "          local indices entries pair",
    "          indices=\"$(\"${COMP_WORDS[0]}\" wallet list-indices \"$_w\" 2>/dev/null)\"",
    "          entries=\"\"",
    "          for idx in $indices; do entries+=\"${_w}/${idx} \"; done",
    "          COMPREPLY=( $(compgen -W \"$entries\" -- \"${_w}/${_suffix}\") )",
    "          ;;",
    "        *)",
    "          local _typed _t _n _eoa=\"\"",
    "          _typed=\"$(\"${COMP_WORDS[0]}\" wallet list-typed-names 2>/dev/null)\"",
    "          while IFS=$'\\t' read -r _t _n; do",
    "            [ -z \"$_n\" ] && continue",
    "            case \"$_t\" in",
    "              eoa) _eoa+=\"${_n}/ \" ;;",
    "            esac",
    "          done <<< \"$_typed\"",
    "          # EOA: trailing slash (more typing follows). We prefer",
    "          # nospace (an EOA insert ends in `/`; the user adds their",
    "          # own space when they're done).",
    "          COMPREPLY=( $(compgen -W \"${_eoa}\" -- \"$_cur\") )",
    "          compopt -o nospace 2>/dev/null",
    "          ;;",
    "      esac",
    "    else",
    "      local names",
    "      names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "      COMPREPLY=( $(compgen -W \"$names\" -- \"$_cur\") )",
    "    fi",
    "  }",
    "  local prev=\"${COMP_WORDS[COMP_CWORD-1]}\"",
    "  if [ \"$prev\" = \"--account\" ]; then",
    "    _leancli_account_value \"$cur\"; return 0",
    "  fi",
    "  case \"$cur\" in",
    "    --account=*)",
    "      _leancli_account_value \"${cur#--account=}\"; return 0 ;;",
    "  esac",
    "  if [ \"$COMP_CWORD\" -eq 1 ]; then",
    "    COMPREPLY=( $(compgen -W \"$top\" -- \"$cur\") ); return 0",
    "  fi",
    "  case \"${COMP_WORDS[1]}\" in",
    "    wallet)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"create import list show address unlock lock delete reveal derive sign-digest sign-message sign-tx sign-typed-data history account use current\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ] && [ \"${COMP_WORDS[2]}\" = \"create\" ]; then COMPREPLY=( $(compgen -W \"eoa\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ] && [ \"${COMP_WORDS[2]}\" = \"account\" ]; then COMPREPLY=( $(compgen -W \"add list rm\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -ge 4 ] && [ \"${COMP_WORDS[2]}\" = \"account\" ]; then",
    "        local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "        COMPREPLY=( $(compgen -W \"$names\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        case \"${COMP_WORDS[2]}\" in",
    "          show|address|unlock|lock|history|list)",
    "            local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "            COMPREPLY=( $(compgen -W \"$names --all -a\" -- \"$cur\") ) ;;",
    "          delete|reveal|derive|sign-digest|sign-message|sign-tx|sign-typed-data|use)",
    "            local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "            COMPREPLY=( $(compgen -W \"$names\" -- \"$cur\") ) ;;",
    "        esac;",
    "      fi ;;",
    "    send)",
    "      # send <to> <amount> [--account <wallet>]",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        _leancli_hint \"$cur\" \"<recipient:0x-address>\" \"<or-ENS:vitalik.eth>\";",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        _leancli_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.01>\";",
    "      elif [ \"$COMP_CWORD\" -eq 4 ]; then",
    "        COMPREPLY=( $(compgen -W \"--account\" -- \"$cur\") );",
    "      fi ;;",
    "    shield)",
    "      # shield <wallet> <eth>  |  shield {balance,reveal,import,delete}",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "        COMPREPLY=( $(compgen -W \"balance reveal import delete $names\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        case \"${COMP_WORDS[2]}\" in",
    "          import) _leancli_hint \"$cur\" \"<bip39-mnemonic-12-or-24-words>\" \"<quote-the-whole-phrase>\" ;;",
    "          balance|reveal|delete) COMPREPLY=() ;;",
    "          *) _leancli_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.01>\" ;;",
    "        esac;",
    "      fi ;;",
    "    unshield)",
    "      # unshield <to> <eth>",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        _leancli_hint \"$cur\" \"<recipient:0x-address>\" \"<or-ENS:vitalik.eth>\";",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        _leancli_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.005>\";",
    "      fi ;;",
    "    resolve)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        _leancli_hint \"$cur\" \"<ens-name:vitalik.eth>\" \"<or-subdomain.eth>\";",
    "      fi ;;",
    "    network)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"show path set-rpc set-lightclient set-policy unset-rpc set-ens-rpc unset-ens-rpc set-rpc-chain unset-rpc-chain set-chain monitor\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ] && [ \"${COMP_WORDS[2]}\" = \"set-policy\" ]; then COMPREPLY=( $(compgen -W \"strict tor permissive\" -- \"$cur\") ); fi ;;",
    "    daemon)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"help start stop restart ping status logs version\" -- \"$cur\") ); fi ;;",
    "    chain)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        COMPREPLY=( $(compgen -W \"balance nonce token-balance gas-price priority-fee estimate-gas broadcast\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        case \"${COMP_WORDS[2]}\" in",
    "          balance|nonce)     _leancli_hint \"$cur\" \"<address:0x...>\" \"<20-byte-hex>\" ;;",
    "          token-balance)     _leancli_hint \"$cur\" \"<token-contract:0x...>\" \"<erc20-address>\" ;;",
    "          estimate-gas)      _leancli_hint \"$cur\" \"<tx-json>\" \"<quote-the-json>\" ;;",
    "          broadcast)         _leancli_hint \"$cur\" \"<raw-tx-hex:0x...>\" \"<rlp-encoded>\" ;;",
    "        esac;",
    "      elif [ \"$COMP_CWORD\" -eq 4 ] && [ \"${COMP_WORDS[2]}\" = \"token-balance\" ]; then",
    "        _leancli_hint \"$cur\" \"<owner-address:0x...>\" \"<20-byte-hex>\";",
    "      fi ;;",
    "    debug)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"policy-check rpc-check rpc-methods endpoint-check decode\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ] && [ \"${COMP_WORDS[2]}\" = \"decode\" ]; then COMPREPLY=( $(compgen -W \"erc20\" -- \"$cur\") ); fi ;;",
    "    policy)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"accounts keystore lightclient network privacy security all\" -- \"$cur\") ); fi ;;",
    "    balance)",
    "      # balance | balance -a | balance <address>",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        case \"$cur\" in",
    "          -*) COMPREPLY=( $(compgen -W \"--all -a\" -- \"$cur\") ) ;;",
    "          *)  _leancli_hint \"$cur\" \"<address:0x...>\" \"<or-flag:-a>\" ;;",
    "        esac;",
    "      fi ;;",
    "    completion)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"bash zsh fish\" -- \"$cur\") ); fi ;;",
    "    from)",
    "      # from <wallet> send <to> <amount>",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "        COMPREPLY=( $(compgen -W \"$names\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        COMPREPLY=( $(compgen -W \"send\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 4 ]; then",
    "        _leancli_hint \"$cur\" \"<recipient:0x-address>\" \"<or-ENS:vitalik.eth>\";",
    "      elif [ \"$COMP_CWORD\" -eq 5 ]; then",
    "        _leancli_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.01>\";",
    "      fi ;;",
    "  esac",
    "}",
    "complete -F _leancli_complete leancli",
    "complete -F _leancli_complete kohaku",
    ""
  ]

/-- Zsh `--account` value override. Plugs into the same trigger points as bash
    (`prev == --account`, `cur == --account=*`) but uses zsh `_describe` so the
    second-stage menu shows `wallet/index  (0xAa65…C02C)`. The address is shown
    only as decoration; `wallet/index` is what gets inserted on selection. -/
def zshAccountOverride : String :=
  String.intercalate "\n" [
    "_leancli_account_zsh() {",
    "  local _cur=\"$1\" _bin=\"$2\"",
    "  local _is_index=0",
    "  if [[ \"${words[2]}\" == \"send\" ]]; then",
    "    _is_index=1",
    "  fi",
    "  if (( _is_index )); then",
    "    if [[ \"$_cur\" == */* ]]; then",
    "      local _w=\"${_cur%%/*}\"",
    "      local -a _pairs _disp",
    "      local _line _pair _addr _short",
    "      while IFS= read -r _line; do",
    "        [[ -z \"$_line\" ]] && continue",
    "        _pair=\"${_line%%$'\\t'*}\"",
    "        _addr=\"${_line#*$'\\t'}\"",
    "        if [[ \"$_addr\" == 0x* && ${#_addr} -ge 12 ]]; then",
    "          _short=\"${_addr:0:6}\\u2026${_addr: -4}\"",
    "        else",
    "          _short=\"$_addr\"",
    "        fi",
    "        _pairs+=(\"$_pair\")",
    "        _disp+=(\"${_pair}:(${_short})\")",
    "      done < <(\"$_bin\" wallet list-walletindices --addresses \"$_w\" 2>/dev/null)",
    "      _describe -t accounts 'account' _disp _pairs",
    "    else",
    "      # EOA → `<name>/` (sub-account form follows). TPM → bare `<name>`.",
    "      local -a _entries",
    "      local _t _n",
    "      while IFS=$'\\t' read -r _t _n; do",
    "        [[ -z \"$_n\" ]] && continue",
    "        case \"$_t\" in",
    "          eoa) _entries+=(\"${_n}/\") ;;",
    "          tpm) _entries+=(\"$_n\") ;;",
    "        esac",
    "      done < <(\"$_bin\" wallet list-typed-names 2>/dev/null)",
    "      compadd -S '' -- \"${_entries[@]}\"",
    "    fi",
    "  else",
    "    local -a _names",
    "    local _n",
    "    while IFS= read -r _n; do",
    "      [[ -z \"$_n\" ]] && continue",
    "      _names+=(\"$_n\")",
    "    done < <(\"$_bin\" wallet list-names 2>/dev/null)",
    "    compadd -- \"${_names[@]}\"",
    "  fi",
    "}",
    "# Wrap the bash-derived completion: intercept --account value completion",
    "# so the zsh menu can carry address annotations via _describe.",
    "_leancli_complete_zsh() {",
    "  local cur=\"${words[CURRENT]}\" prev=\"${words[CURRENT-1]}\"",
    "  local bin=\"${words[1]}\"",
    "  if [[ \"$prev\" == \"--account\" ]]; then",
    "    _leancli_account_zsh \"$cur\" \"$bin\"; return 0",
    "  fi",
    "  case \"$cur\" in",
    "    --account=*) _leancli_account_zsh \"${cur#--account=}\" \"$bin\"; return 0 ;;",
    "  esac",
    "  _leancli_complete",
    "}",
    "compdef _leancli_complete_zsh leancli kohaku",
    ""
  ]

def zshCompletion : String :=
  "#compdef leancli kohaku\nautoload -U bashcompinit && bashcompinit\n" ++ bashCompletion ++ "\n" ++ zshAccountOverride

/-- Native fish completion. Unlike the zsh emitter (which wraps the bash
    script under `bashcompinit`), this is written in fish's `complete`
    syntax directly so we get descriptions in the tab menu and use fish's
    native `commandline` / `string` builtins for the `--account` dynamic
    case. Helper functions (`__leancli_bin`, `__leancli_wallet_names`,
    `__leancli_account_send_values`) are auto-loaded by fish when the file
    lands under `~/.config/fish/completions/leancli.fish`. -/
def fishCompletion : String :=
  String.intercalate "\n" [
    "# leancli / leancli fish completion",
    "",
    "# Resolve the binary fish is completing for (`leancli` vs `leancli`)",
    "# so dynamic completions invoke the same path the user typed.",
    "function __leancli_bin",
    "    set -l toks (commandline -opc)",
    "    if test (count $toks) -ge 1",
    "        echo $toks[1]",
    "    else",
    "        echo leancli",
    "    end",
    "end",
    "",
    "function __leancli_wallet_names",
    "    set -l bin (__leancli_bin)",
    "    $bin wallet list-names 2>/dev/null",
    "end",
    "",
    "# --account candidates for `send`: <wallet>/<idx> for EOAs.",
    "# Mirrors the bash emitter's _leancli_account_value index-mode branch.",
    "function __leancli_account_send_values",
    "    set -l bin (__leancli_bin)",
    "    set -l cur (commandline -ct)",
    "    set cur (string replace -r '^--account=' '' -- $cur)",
    "    if string match -q '*/*' -- $cur",
    "        set -l parts (string split -m1 / -- $cur)",
    "        set -l wallet $parts[1]",
    "        for idx in ($bin wallet list-indices $wallet 2>/dev/null)",
    "            echo \"$wallet/$idx\"",
    "        end",
    "    else",
    "        $bin wallet list-typed-names 2>/dev/null | while read -l line",
    "            set -l fields (string split \\t -- $line)",
    "            test (count $fields) -ge 2; or continue",
    "            switch $fields[1]",
    "                case eoa",
    "                    echo \"$fields[2]/\"",
    "                case tpm",
    "                    echo \"$fields[2]\"",
    "            end",
    "        end",
    "    end",
    "end",
    "",
    "# Suppress fallback file completion across the whole command surface.",
    "complete -c leancli     -f",
    "complete -c kohaku      -f",
    "",
    "# --- top-level verbs ---",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a help          -d 'Show usage'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a version       -d 'Print version'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a doctor        -d 'Implementation/check status'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a policy        -d 'Show internal policy reference'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a network       -d 'Network/RPC configuration'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a wallet        -d 'Wallet management'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a shield        -d 'Privacy-Pools deposit / status'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a unshield      -d 'Privacy-Pools withdrawal'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a daemon        -d 'Daemon control'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a balance       -d 'Read ETH balance of one address'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a balances      -d 'Per-token balances for one address'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a list          -d 'Tree view of wallets'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a send          -d 'Send ETH'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a from          -d 'Per-wallet send: from <wallet> send …'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a chain         -d 'Low-level chain utilities'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a debug         -d 'Debug / simulation'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a resolve       -d 'Resolve ENS name to address'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a tui           -d 'Open the interactive TUI'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a ui            -d 'Alias for tui'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a install       -d 'Rebuild + relink ~/.leancli/bin'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a update        -d 'git pull + rebuild + relink'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a uninstall     -d 'Remove ~/.leancli/bin symlinks'",
    "complete -c leancli -c kohaku -n __fish_use_subcommand -a completion    -d 'Print a shell completion script'",
    "",
    "# --- wallet ---",
    "set -l __leancli_wallet_verbs create import deploy list show address unlock lock delete reveal derive sign-digest sign-message sign-tx sign-typed-data history account use current master enroll",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from wallet; and not __fish_seen_subcommand_from create import deploy list show address unlock lock delete reveal derive sign-digest sign-message sign-tx sign-typed-data history account use current master enroll' -a \"$__leancli_wallet_verbs\"",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from wallet; and __fish_seen_subcommand_from create; and not __fish_seen_subcommand_from eoa' -a 'eoa' -d 'Account type'",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from wallet; and __fish_seen_subcommand_from account; and not __fish_seen_subcommand_from add list rm' -a 'add list rm' -d 'Sub-account op'",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from wallet; and __fish_seen_subcommand_from master; and not __fish_seen_subcommand_from init status set-timeout bind-tpm' -a 'init status set-timeout bind-tpm' -d 'Master KEK op'",
    "# Dynamic wallet names for verbs that take a single <name>.",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from wallet; and __fish_seen_subcommand_from show address unlock lock delete reveal derive sign-digest sign-message sign-tx sign-typed-data history deploy use enroll' -a '(__leancli_wallet_names)' -d Wallet",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from wallet; and __fish_seen_subcommand_from account; and __fish_seen_subcommand_from add list rm' -a '(__leancli_wallet_names)' -d Wallet",
    "",
    "# --- send / from / --account ---",
    "complete -c leancli -c kohaku -l account -r -d 'Wallet' -n 'not __fish_seen_subcommand_from send' -a '(__leancli_wallet_names)'",
    "complete -c leancli -c kohaku -l account -r -d 'Wallet/<index>' -n '__fish_seen_subcommand_from send' -a '(__leancli_account_send_values)'",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from from; and not __fish_seen_subcommand_from send' -a '(__leancli_wallet_names)' -d Wallet",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from from; and __fish_seen_subcommand_from send' -a send",
    "",
    "# --- shield ---",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from shield; and not __fish_seen_subcommand_from balance reveal import delete' -a 'balance reveal import delete' -d 'PP op'",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from shield; and not __fish_seen_subcommand_from balance reveal import delete' -a '(__leancli_wallet_names)' -d Wallet",
    "",
    "# --- network ---",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from network; and not __fish_seen_subcommand_from show path set-rpc set-lightclient set-policy unset-rpc set-ens-rpc unset-ens-rpc set-rpc-chain unset-rpc-chain set-chain monitor' -a 'show path set-rpc set-lightclient set-policy unset-rpc set-ens-rpc unset-ens-rpc set-rpc-chain unset-rpc-chain set-chain monitor'",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from network; and __fish_seen_subcommand_from set-policy' -a 'strict tor permissive' -d Policy",
    "",
    "# --- daemon ---",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from daemon; and not __fish_seen_subcommand_from help start stop restart ping status logs version' -a 'help start stop restart ping status logs version' -d 'Daemon op'",
    "",
    "# --- chain ---",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from chain; and not __fish_seen_subcommand_from balance nonce token-balance gas-price priority-fee estimate-gas broadcast' -a 'balance nonce token-balance gas-price priority-fee estimate-gas broadcast'",
    "",
    "# --- debug ---",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from debug; and not __fish_seen_subcommand_from policy-check rpc-check rpc-methods endpoint-check decode' -a 'policy-check rpc-check rpc-methods endpoint-check decode'",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from debug; and __fish_seen_subcommand_from decode' -a erc20",
    "",
    "# --- policy ---",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from policy; and not __fish_seen_subcommand_from accounts keystore lightclient network privacy security all' -a 'accounts keystore lightclient network privacy security all'",
    "",
    "# --- completion ---",
    "complete -c leancli -c kohaku -n '__fish_seen_subcommand_from completion; and not __fish_seen_subcommand_from bash zsh fish' -a 'bash zsh fish' -d Shell",
    ""
  ]

end LeanCli.Cli.Commands
