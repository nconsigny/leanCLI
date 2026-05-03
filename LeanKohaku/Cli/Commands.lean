import LeanKohaku.Cli.DaemonClient
import LeanKohaku.Cli.Passphrase
import LeanKohaku.Encoding.Json
import LeanKohaku.Network.Endpoint
import LeanKohaku.Network.Provider

/-!
# CLI commands

The CLI is the primary user surface. It speaks to the daemon over the
local socket; commands that need the daemon use socket activation when present
or auto-spawn `leankohaku-daemon` as a local fallback.
-/

namespace LeanKohaku.Cli.Commands

open LeanKohaku.Privacy.NetworkPolicy
open LeanKohaku.Network.Provider
open LeanKohaku.Network.Endpoint

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
  | walletDelete (name : String)
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
  | networkMonitor
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
  | daemon      -- run the daemon (same as `leankohaku-daemon`)
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
  | accountListIndices (wallet? : Option String)
  | accountListWalletIndices (withAddresses : Bool) (wallet? : Option String)
  | shieldedBalance
  | shieldedDeposit (walletName : String) (amountEth : String)
  | shieldedWithdraw (recipient amountEth : String)
  | shieldedReveal
  | shieldedImport (mnemonic : String)
  | shieldedDelete
  | completion (shell : String)
  | resolve (name : String)
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
  | ["wallet", "unlock", name] => .walletUnlock name
  | ["wallet", "lock", "--all"] => .walletLockAll
  | ["wallet", "lock", "-a"] => .walletLockAll
  | ["wallet", "lock", name] => .walletLock name
  | ["wallet", "delete", name] => .walletDelete name
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
  | ["network", "monitor"]                 => .networkMonitor
  | ["doctor"]            => .doctor
  | ["daemon", "help"] => .daemonHelp none
  | ["daemon", "ping"] => .daemonPing
  | ["daemon", "version"] => .daemonVersion
  | ["daemon", "stop"] => .daemonStop
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
  | ["shield", walletName, amountEth] => .shieldedDeposit walletName amountEth
  | ["unshield", to, amountEth] => .shieldedWithdraw to amountEth
  | ["completion", shell]  => .completion shell
  | ["resolve", name]      => .resolve name
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
       usage: leankohaku policy-check <policy> <peer> <purpose> <transport>\n\
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
       usage: leankohaku rpc-check <policy> <backend> <transport> <rpc-method>\n\
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
       usage: leankohaku endpoint-check <strict|tor> <kind> <scheme> <transport> <credentialed>\n\
       kinds: " ++ joinComma kindNames ++ "\n\
       schemes: " ++ joinComma schemeNames ++ "\n\
       transports: " ++ joinComma transportNames ++ "\n\
       credentialed: true, false"

def privacyText : String :=
  "leanKohaku privacy policy\n\n\
   CLI:\n\
     - only local daemon control over loopback is allowed\n\
     - direct node, indexer, analytics, price, fiat, metadata, discovery, and crash-report calls are denied\n\n\
   Daemon:\n\
     - local/light-client reads use loopback\n\
     - local transaction broadcast uses loopback\n\
     - configured-node traffic is denied in strict mode\n\
     - Tor mode may read or broadcast through a configured node over Tor\n\
     - third-party APIs remain denied even when Tor is enabled\n\n\
   Policy modules: LeanKohaku.Privacy.NetworkPolicy, LeanKohaku.Network.Provider.\n"

def networkText : String :=
  "leanKohaku network surface\n\n\
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
  "leanKohaku security posture\n\n\
   Hard rules:\n\
     - deny by default\n\
     - CLI never talks to nodes or third-party services\n\
     - strict daemon mode is local/light-client only\n\
     - configured-node access requires Tor mode\n\
     - only eth_sendRawTransaction is a broadcast purpose\n\
     - no analytics, telemetry, price APIs, fiat/onramp APIs, indexers, metadata lookup, peer discovery, or crash uploads\n\n\
   Useful checks:\n\
     leankohaku policy-check strict configured-node broadcast-tx direct\n\
     leankohaku policy-check tor configured-node node-read tor\n\
     leankohaku rpc-check strict configured direct eth_getBalance\n\
     leankohaku rpc-check tor configured tor eth_sendRawTransaction\n\
     leankohaku endpoint-check strict local http loopback false\n\
     leankohaku endpoint-check tor configured onion tor false\n"

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
  "leanKohaku doctor\n\n\
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
     ./script/check_privacy_cli.sh\n"

def daemonHelpText (walletName? : Option String) : String :=
  let walletName := walletName?.getD "<wallet>"
  "leanKohaku daemon wallet commands\n\n\
   Primary command shape:\n\
     leankohaku daemon <wallet> send <chain> <to> <eth>\n\n\
   Example:\n\
     leankohaku daemon " ++ walletName ++ " send sepolia 0xAa651C04bfE4F302eE243D6638d3B91389C4C02C 0.002\n\n\
   Arguments:\n\
     <wallet>  Local TPM key slot name, for example daily or sepolia-r1\n\
     <chain>   sepolia today; mainnet is intentionally disabled until production R1 deployment\n\
     <to>      20-byte Ethereum address, 0x-prefixed\n\
     <eth>     Human ETH amount, for example 0, 0.001, or 0.002\n\n\
   What happens on Sepolia:\n\
     1. Read the deployed R1 account address for the wallet key\n\
     2. Convert ETH to wei locally with cast\n\
     3. Ask the R1 account for the operation digest\n\
     4. Require fprintd biometric verification, default right-index-finger, up to 3 tries\n\
     5. Sign the digest with the local TPM P-256 key\n\
     6. Broadcast execute(...) through the deployed R1 account\n\n\
   Setup commands:\n\
     leankohaku wallet create r1 " ++ walletName ++ "\n\
     leankohaku wallet deploy " ++ walletName ++ "\n\
     LEAN_KOHAKU_TPM_KEY=" ++ walletName ++ " ./script/r1_sepolia.sh deploy\n\n\
   Inspect:\n\
     leankohaku wallet list\n\
     ./script/r1_sepolia.sh address\n\n\
   Safety notes:\n\
     - The TPM private blob stays local under .leankohaku/ and is gitignored\n\
     - Fingerprint verification gates signing but is not yet a TPM policy session\n\
     - The current Sepolia contract is a temporary Solidity fallback\n\
     - Contracts/R1Account/ remains the Lean/Verity source of truth\n"

def lightclientText : String :=
  "leanKohaku provider policy plan\n\n\
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
   See LeanKohaku.Network.Provider and LeanKohaku.Invariants.Network.\n"

def keystoreText : String :=
  "leanKohaku local keystore policy\n\n\
   Boundary:\n\
     - keystore access is local-only; no online or remote keystore service\n\
     - wallet code must never receive raw private keys or seed material\n\
     - normal operations deny key import/export\n\
     - signing requires hardware-backed key custody and user authorization\n\n\
   Platform notes:\n\
     - Ethereum mainnet is production; Sepolia is explicit dev/testnet support\n\
     - macOS/iOS native Secure Enclave is modeled for P-256/R1\n\
     - Linux profiles prefer TPM2 on common HP/Lenovo hardware, with FIDO2 fallback\n\
     - the Linux kernel keyring is modeled as local handle storage, not signing\n\
     - account logic verifies R1 signatures with the P256VERIFY precompile model\n\n\
   Runtime:\n\
     - wallet create r1 <name> creates a chain-agnostic TPM2-wrapped P-256 key\n\
     - wallet deploy r1 <name> --chain sepolia deploys the R1 smart account on Sepolia\n\
     - wallet sign sepolia <name> <digest> signs a 32-byte digest locally\n\
     - new key creation requires local fprintd biometric verification\n\
     - signing requires local fprintd biometric verification\n\
     - key material is stored under .leankohaku/ and is ignored by git\n\n\
   See LeanKohaku.Keystore.Enclave, LeanKohaku.Keystore.Linux, and\n\
   LeanKohaku.Keystore.Tpm2Runtime.\n"

def accountsText : String :=
  "leanKohaku account policy\n\n\
   Supported account families:\n\
     - eoa-k1: regular BIP-39/BIP-32 Ethereum EOA with k1 signing\n\
     - r1-smart: local hardware-backed P-256/R1 account using EIP-7951 verification\n\n\
   Defaults:\n\
     - eoa-k1 path: m/44'/60'/0'/0/0\n\
     - r1-smart key source: local enclave / TPM / FIDO / Secure Enclave class backend\n\
     - chain: Ethereum mainnet by default; Sepolia is available for dev/testing\n\
     - custody: local only; no online keystore\n\n\
   See LeanKohaku.Wallet.Account and LeanKohaku.Invariants.Account.\n"

def policyTopicNames : List String :=
  ["accounts", "keystore", "lightclient", "network", "privacy", "security"]

def policyOverviewText : String :=
  "leanKohaku policy reference\n\n\
   Topics:\n\
     accounts     — supported account families and defaults\n\
     keystore     — local keystore custody policy\n\
     lightclient  — provider-policy plan and privacy constraints\n\
     network      — allowed JSON-RPC purposes and denied surfaces\n\
     privacy      — network privacy policy summary\n\
     security     — hard rules and useful checks\n\n\
   Run `kohaku policy <topic>` for detail. Run `kohaku policy all` for everything.\n"

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
  "leankohaku — formally-verified Ethereum wallet (Lean 4)\n\n\
   USAGE:\n\
     leankohaku <command> [args]\n\n\
   MAIN COMMANDS:\n\
     send <to> <amount> [--account <wallet>]\n\
                                         Send ETH from the default wallet (set via 'wallet use').\n\
                                         <to> is 0x... or ENS. <amount> is human ETH.\n\
     from <wallet> send <to> <amount>    Send ETH from a specific wallet (eoa or r1),\n\
                                         bypassing the default. Tab-completes <wallet>.\n\
     balance | balance -a                Sum balances across all wallets (Sepolia).\n\
                                         With -a also adds shielded (Privacy-Pools) totals.\n\
     balance <address>                   Read ETH balance of one address.\n\
     list | list -a                      Tree view of EOA + TPM/R1 wallets.\n\
     wallet use <wallet>                 Set default wallet for `send`.\n\
     wallet current                      Print current default wallet.\n\
     resolve <name>                      Resolve an ENS name to an address.\n\n\
   SETUP / WALLET MANAGEMENT:\n\
     wallet create eoa <name> [path]     Create an encrypted EOA slot.\n\
     wallet create r1 <name>             Create a TPM2-wrapped P-256 key.\n\
     wallet import <name> [path] <words> Import a BIP-39 mnemonic as an EOA slot (EOA only).\n\
     wallet deploy <name>                Deploy the R1 smart account on the configured chain (R1 only).\n\
     wallet list                         Tabular list of every wallet (eoa + r1).\n\
     wallet show <name>                  Type-aware metadata.\n\
     wallet address <name>               Primary address.\n\
     wallet unlock <name>                EOA: passphrase prompt; R1: no-op.\n\
     wallet lock <name>                  Lock a wallet.\n\
     wallet delete <name>                Delete a wallet (passphrase required for EOA).\n\
     wallet derive <name> <path>         Derive an extra path (EOA only).\n\
     wallet sign-digest <name> <hash>    Sign a 32-byte digest. Both types.\n\
     wallet sign-message <name> [path] <msg>\n\
                                         Personal-message sign. Both types.\n\
     wallet sign-tx <name> [path] <tx-json>\n\
                                         Sign a transaction. Both types.\n\
     wallet sign-typed-data <name> [path] <json>\n\
                                         EIP-712 sign (EOA only).\n\
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
     unshield <to> <eth>                 Privacy-Pools withdrawal via the relayer.\n\n\
   CHAIN UTILITIES (advanced):\n\
     chain balance <addr> | nonce <addr> | gas-price | priority-fee\n\
     chain token-balance <token> <owner>\n\
     chain estimate-gas <tx-json> | broadcast <raw-tx>\n\n\
   NETWORK CONFIG:\n\
     network show | network path\n\
     network set-rpc <url> [transport]\n\
     network set-lightclient <url>\n\
     network set-policy <strict|tor>\n\
     network unset-rpc\n\
     network set-ens-rpc <url> | network unset-ens-rpc\n\
     network set-rpc-chain <chain> <url> [transport]\n\
     network unset-rpc-chain <chain>\n\
     network monitor\n\n\
   DAEMON / DOCS:\n\
     daemon | daemon ping | daemon version | daemon stop\n\
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
     completion bash | completion zsh    Print a completion script\n\
     # bash:\n\
     #   kohaku completion bash > ~/.local/share/bash-completion/completions/kohaku\n\
     # zsh (after `autoload -U bashcompinit && bashcompinit`):\n\
     #   kohaku completion zsh > \"${fpath[1]}/_kohaku\"\n"

def bashCompletion : String :=
  String.intercalate "\n" [
    "# leankohaku / kohaku bash completion",
    "_leankohaku_complete() {",
    "  local cur",
    "  cur=\"${COMP_WORDS[COMP_CWORD]}\"",
    "  local top=\"help version policy network doctor wallet shield unshield daemon balance list send from chain debug resolve\"",
    "  # If we're completing the value after --account, decide whether the value",
    "  # is a wallet name (e.g. for `daemon <wallet> send`) or a sub-account index",
    "  # (e.g. for `send` and `eoa send|sign-*|send-wei`).",
    "  # Hint helper: display placeholder label(s) for a free-form positional",
    "  # slot (address, amount, ENS name, hex digest…). Forces ≥2 entries when",
    "  # cur is empty so bash lists them without auto-inserting any. Filters",
    "  # by cur prefix once the user starts typing — hints disappear, real",
    "  # input takes over. Disables filename fallback so we don't suggest",
    "  # files for a wei amount.",
    "  _leankohaku_hint() {",
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
    "  _leankohaku_account_value() {",
    "    # $1 = current word being completed",
    "    local _cur=\"$1\"",
    "    local _sub=\"\" _is_index=0",
    "    # Index-mode commands: --account <wallet>/<idx>. Otherwise: wallet name only.",
    "    if [ \"${COMP_WORDS[1]}\" = \"send\" ]; then",
    "      _is_index=1",
    "    fi",
    "    if [ \"$_is_index\" = \"1\" ]; then",
    "      # Two-stage UX: <wallet>/<index>. Detect by presence of a slash.",
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
    "          local names slashed",
    "          names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "          slashed=\"\"",
    "          for n in $names; do slashed+=\"${n}/ \"; done",
    "          COMPREPLY=( $(compgen -W \"$slashed\" -- \"$_cur\") )",
    "          # Don't append a space so the user keeps typing past the slash.",
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
    "    _leankohaku_account_value \"$cur\"; return 0",
    "  fi",
    "  case \"$cur\" in",
    "    --account=*)",
    "      _leankohaku_account_value \"${cur#--account=}\"; return 0 ;;",
    "  esac",
    "  if [ \"$COMP_CWORD\" -eq 1 ]; then",
    "    COMPREPLY=( $(compgen -W \"$top\" -- \"$cur\") ); return 0",
    "  fi",
    "  case \"${COMP_WORDS[1]}\" in",
    "    wallet)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"create import deploy list show address unlock lock delete derive sign-digest sign-message sign-tx sign-typed-data history account use current\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ] && [ \"${COMP_WORDS[2]}\" = \"create\" ]; then COMPREPLY=( $(compgen -W \"eoa r1\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ] && [ \"${COMP_WORDS[2]}\" = \"account\" ]; then COMPREPLY=( $(compgen -W \"add list rm\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -ge 4 ] && [ \"${COMP_WORDS[2]}\" = \"account\" ]; then",
    "        local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "        COMPREPLY=( $(compgen -W \"$names\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        case \"${COMP_WORDS[2]}\" in",
    "          show|address|unlock|lock|history|list)",
    "            local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "            COMPREPLY=( $(compgen -W \"$names --all -a\" -- \"$cur\") ) ;;",
    "          deploy|delete|derive|sign-digest|sign-message|sign-tx|sign-typed-data|use)",
    "            local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "            COMPREPLY=( $(compgen -W \"$names\" -- \"$cur\") ) ;;",
    "        esac;",
    "      fi ;;",
    "    send)",
    "      # send <to> <amount> [--account <wallet>]",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        _leankohaku_hint \"$cur\" \"<recipient:0x-address>\" \"<or-ENS:vitalik.eth>\";",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        _leankohaku_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.01>\";",
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
    "          import) _leankohaku_hint \"$cur\" \"<bip39-mnemonic-12-or-24-words>\" \"<quote-the-whole-phrase>\" ;;",
    "          balance|reveal|delete) COMPREPLY=() ;;",
    "          *) _leankohaku_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.01>\" ;;",
    "        esac;",
    "      fi ;;",
    "    unshield)",
    "      # unshield <to> <eth>",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        _leankohaku_hint \"$cur\" \"<recipient:0x-address>\" \"<or-ENS:vitalik.eth>\";",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        _leankohaku_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.005>\";",
    "      fi ;;",
    "    resolve)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        _leankohaku_hint \"$cur\" \"<ens-name:vitalik.eth>\" \"<or-subdomain.eth>\";",
    "      fi ;;",
    "    network)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"show path set-rpc set-lightclient set-policy unset-rpc set-ens-rpc unset-ens-rpc set-rpc-chain unset-rpc-chain monitor\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ] && [ \"${COMP_WORDS[2]}\" = \"set-policy\" ]; then COMPREPLY=( $(compgen -W \"strict tor\" -- \"$cur\") ); fi ;;",
    "    daemon)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"help ping version stop\" -- \"$cur\") ); fi ;;",
    "    chain)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        COMPREPLY=( $(compgen -W \"balance nonce token-balance gas-price priority-fee estimate-gas broadcast\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        case \"${COMP_WORDS[2]}\" in",
    "          balance|nonce)     _leankohaku_hint \"$cur\" \"<address:0x...>\" \"<20-byte-hex>\" ;;",
    "          token-balance)     _leankohaku_hint \"$cur\" \"<token-contract:0x...>\" \"<erc20-address>\" ;;",
    "          estimate-gas)      _leankohaku_hint \"$cur\" \"<tx-json>\" \"<quote-the-json>\" ;;",
    "          broadcast)         _leankohaku_hint \"$cur\" \"<raw-tx-hex:0x...>\" \"<rlp-encoded>\" ;;",
    "        esac;",
    "      elif [ \"$COMP_CWORD\" -eq 4 ] && [ \"${COMP_WORDS[2]}\" = \"token-balance\" ]; then",
    "        _leankohaku_hint \"$cur\" \"<owner-address:0x...>\" \"<20-byte-hex>\";",
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
    "          *)  _leankohaku_hint \"$cur\" \"<address:0x...>\" \"<or-flag:-a>\" ;;",
    "        esac;",
    "      fi ;;",
    "    completion)",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then COMPREPLY=( $(compgen -W \"bash zsh\" -- \"$cur\") ); fi ;;",
    "    from)",
    "      # from <wallet> send <to> <amount>",
    "      if [ \"$COMP_CWORD\" -eq 2 ]; then",
    "        local names; names=\"$(\"${COMP_WORDS[0]}\" wallet list-names 2>/dev/null)\"",
    "        COMPREPLY=( $(compgen -W \"$names\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 3 ]; then",
    "        COMPREPLY=( $(compgen -W \"send\" -- \"$cur\") );",
    "      elif [ \"$COMP_CWORD\" -eq 4 ]; then",
    "        _leankohaku_hint \"$cur\" \"<recipient:0x-address>\" \"<or-ENS:vitalik.eth>\";",
    "      elif [ \"$COMP_CWORD\" -eq 5 ]; then",
    "        _leankohaku_hint \"$cur\" \"<amount-in-ETH>\" \"<example:0.01>\";",
    "      fi ;;",
    "  esac",
    "}",
    "complete -F _leankohaku_complete leankohaku",
    "complete -F _leankohaku_complete kohaku",
    ""
  ]

/-- Zsh `--account` value override. Plugs into the same trigger points as bash
    (`prev == --account`, `cur == --account=*`) but uses zsh `_describe` so the
    second-stage menu shows `wallet/index  (0xAa65…C02C)`. The address is shown
    only as decoration; `wallet/index` is what gets inserted on selection. -/
def zshAccountOverride : String :=
  String.intercalate "\n" [
    "_leankohaku_account_zsh() {",
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
    "      local -a _names _slashed",
    "      local _n",
    "      while IFS= read -r _n; do",
    "        [[ -z \"$_n\" ]] && continue",
    "        _slashed+=(\"${_n}/\")",
    "      done < <(\"$_bin\" wallet list-names 2>/dev/null)",
    "      compadd -S '' -- \"${_slashed[@]}\"",
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
    "_leankohaku_complete_zsh() {",
    "  local cur=\"${words[CURRENT]}\" prev=\"${words[CURRENT-1]}\"",
    "  local bin=\"${words[1]}\"",
    "  if [[ \"$prev\" == \"--account\" ]]; then",
    "    _leankohaku_account_zsh \"$cur\" \"$bin\"; return 0",
    "  fi",
    "  case \"$cur\" in",
    "    --account=*) _leankohaku_account_zsh \"${cur#--account=}\" \"$bin\"; return 0 ;;",
    "  esac",
    "  _leankohaku_complete",
    "}",
    "compdef _leankohaku_complete_zsh leankohaku kohaku",
    ""
  ]

def zshCompletion : String :=
  "#compdef leankohaku kohaku\nautoload -U bashcompinit && bashcompinit\n" ++ bashCompletion ++ "\n" ++ zshAccountOverride

end LeanKohaku.Cli.Commands
