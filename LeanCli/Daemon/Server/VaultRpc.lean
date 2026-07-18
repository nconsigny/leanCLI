import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.State
import LeanCli.Daemon.StateVault
import LeanCli.Daemon.TokenMeta
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Mpt
import LeanCli.Crypto.Hex
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server

/-!
# Daemon server: `vault.*` RPC family — the partial state node

Surfaces the StateVault (persistent, provenance-tagged partial chain
state) to the CLI/TUI/agent:

  vault.status      — row counts, DB path, enabled flag
  vault.captureHead — pin the current verified head (block, stateRoot)
  vault.pin         — the FULL partial-state-node flow: verified head →
                      `eth_getProof` from the (untrusted) configured RPC →
                      Merkle-Patricia verification IN LEAN against the
                      verified state root → store account + slots at that
                      exact block, tier `leanProven`
  vault.get         — serve stored state for an address, explicitly
                      "as of block N" with its tier (never head state)
  vault.tokens      — stored token metadata for a chain

Provenance honesty: `captureHead` reads the head through the verified
backend's `runCall` DIRECTLY (not `Outbound.call`), because Outbound
silently degrades to plain HTTP when the light client cannot serve a
read — correct for availability, but it would let an unverified value
be recorded as `consensusVerified`. Here the verified attempt either
succeeds (tier `consensus`) or we fall back EXPLICITLY and record tier
`rpc`.

Trust posture: everything here is display/offline tier. Nothing served
from the vault gates a signature — the pre-sign pipeline is unchanged.
-/

namespace LeanCli.Daemon.Server.VaultRpc

open LeanCli.Encoding.Json
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- JSON-RPC error when the vault is disabled or failed to open. -/
def vaultDisabled : RpcError :=
  { code := -32040, message := "statevault disabled",
    data := some (.str "vault is off (LEANCLI_VAULT=0) or failed to open") }

private def vaultFailed (what : String) (detail : String) : RpcError :=
  { code := -32041, message := what, data := some (.str detail) }

/-- Strip `0x`, left-pad to even length, hex-decode. -/
private def hexToBytes? (s : String) : Option ByteArray :=
  let t := (s.dropPrefix "0x").toString
  let t := if t.length % 2 == 1 then "0" ++ t else t
  LeanCli.Crypto.Hex.decode t

/-- Left-pad a byte array to 32 bytes (storage-slot key convention). -/
private def padTo32 (b : ByteArray) : ByteArray :=
  if b.size ≥ 32 then b
  else
    let zeros := ByteArray.mk (Array.replicate (32 - b.size) 0)
    zeros ++ b

-- NB: `Hex.encode` already emits the `0x` prefix.
private def bytesToHex0x (b : ByteArray) : String :=
  LeanCli.Crypto.Hex.encode b

/-- Read the current head header through the verified backend with NO
    silent downgrade: a light-client hit is `consensusVerified`, anything
    else is an explicit direct-RPC fallback recorded as `rpcUnverified`.
    Returns the entry already persisted to the vault (best-effort). -/
def captureHead (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (ep : LeanCli.RPC.Outbound.Endpoint) (chainId : Nat) :
    IO (Except String LeanCli.Daemon.StateVault.HeaderEntry) := do
  let params : Json := .arr #[.str "latest", .bool false]
  -- Verified attempt (helios → colibri per the provider cascade).
  let viaResult? ← do
    match ← LeanCli.Daemon.State.buildVerifiedReadVia state chainId ep.url with
    | none => pure none
    | some via =>
        match ← via.runCall .getBlockByNumber params with
        | .ok j => pure (some j)
        | _ => pure none
  let (blockJson?, tier) ← do
    match viaResult? with
    | some j => pure (some j, LeanCli.Daemon.StateVault.Tier.consensusVerified)
    | none =>
        match ← LeanCli.RPC.Outbound.getBlockByNumber cfg.policy ep "latest" false none with
        | .ok j => pure (some j, LeanCli.Daemon.StateVault.Tier.rpcUnverified)
        | .error _ => pure (none, LeanCli.Daemon.StateVault.Tier.rpcUnverified)
  match blockJson? with
  | none => pure (.error "head fetch failed on both verified and direct paths")
  | some block =>
      let getStr (k : String) : Option String := getField k block >>= asString
      match getStr "number" >>= parseHexQuantity, getStr "stateRoot" with
      | some number, some stateRoot =>
          let entry : LeanCli.Daemon.StateVault.HeaderEntry := {
            chainId,
            blockNumber := number,
            blockHash := (getStr "hash").getD "",
            stateRoot,
            timestamp := ((getStr "timestamp").bind parseHexQuantity).getD 0,
            tier }
          let _ ← LeanCli.Daemon.State.withVault state
            (fun h => LeanCli.Daemon.StateVault.putHeader h entry)
          pure (.ok entry)
      | _, _ => pure (.error "head block missing number/stateRoot")

/-- Parse one `storageProof` element of an `eth_getProof` result into
    `(slotHex, proofNodes)`. -/
private def parseStorageProofEntry (j : Json) :
    Option (String × List ByteArray) := do
  let key ← getField "key" j >>= asString
  let proofArr ← match getField "proof" j with
    | some (.arr xs) => some xs
    | _ => none
  let nodes ← proofArr.toList.mapM (fun p => asString p >>= hexToBytes?)
  pure (key, nodes)

/-- Prove one address (+ optional storage slots) against an ALREADY
    captured head, verify in Lean, store at that exact block. The shared
    core of `vault.pin` (single, caller-supplied slots) and
    `vault.pinAccounts` (batch over owned accounts). Returns the summary
    JSON on success; a string error when nothing was proven — callers
    must treat that exactly like a failed network read. -/
def pinAddress (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (ep : LeanCli.RPC.Outbound.Endpoint) (chainId : Nat)
    (head : LeanCli.Daemon.StateVault.HeaderEntry)
    (address : String) (slots : Array String) :
    IO (Except String Json) := do
  let blockHex := natQuantityHex head.blockNumber
  -- Proof from the UNTRUSTED direct RPC (via? = none: the proof carries
  -- its own integrity, Lean checks it against the captured stateRoot).
  let slotJson : Array Json := slots.map (fun s => .str s)
  match ← LeanCli.RPC.Outbound.getProof cfg.policy ep address slotJson blockHex none with
  | .error e => pure (.error s!"eth_getProof failed: {e}")
  | .ok proofJson =>
      let stateRoot? := hexToBytes? head.stateRoot
      let addr20? := hexToBytes? address
      let acctProof? : Option (List ByteArray) :=
        match getField "accountProof" proofJson with
        | some (.arr xs) =>
            xs.toList.mapM (fun p => asString p >>= hexToBytes?)
        | _ => none
      match stateRoot?, addr20?, acctProof? with
      | some stateRoot, some addr20, some acctProof =>
          match ← LeanCli.Ethereum.Mpt.verifyAccountProofIO
              stateRoot addr20 acctProof with
          | .error e => pure (.error s!"account proof rejected: {e}")
          | .ok verdict =>
              let tier := LeanCli.Daemon.StateVault.pinTier head.tier
              let (balance, nonce, storageRoot, codeHash) :=
                match verdict with
                | some acct =>
                    (acct.balance, acct.nonce,
                     bytesToHex0x acct.storageRoot,
                     bytesToHex0x acct.codeHash)
                | none =>
                    -- Proven absent: canonical empty account.
                    (0, 0,
                     "0x" ++ LeanCli.Ethereum.Mpt.emptyTrieRootHex,
                     "0x" ++ LeanCli.Ethereum.Mpt.emptyCodeHashHex)
              let acctEntry : LeanCli.Daemon.StateVault.AccountEntry := {
                chainId, addr := address.toLower,
                blockNumber := head.blockNumber,
                balanceHex := natQuantityHex balance,
                nonce,
                storageRoot, codeHash, tier }
              let _ ← LeanCli.Daemon.State.withVault state
                (fun h => LeanCli.Daemon.StateVault.putAccount h acctEntry)
              -- Storage-slot proofs against the PROVEN storageRoot (not
              -- the RPC's claimed one).
              let storageRootBytes :=
                match verdict with
                | some acct => acct.storageRoot
                | none => LeanCli.Ethereum.Mpt.emptyTrieRoot
              let mut slotResults : Array Json := #[]
              let storageProofs : Array Json :=
                match getField "storageProof" proofJson with
                | some (.arr xs) => xs
                | _ => #[]
              for sp in storageProofs do
                match parseStorageProofEntry sp with
                | none =>
                    slotResults := slotResults.push <| .obj #[
                      ("error", .str "malformed storageProof entry")]
                | some (slotHex, nodes) =>
                    match hexToBytes? slotHex with
                    | none =>
                        slotResults := slotResults.push <| .obj #[
                          ("slot", .str slotHex),
                          ("error", .str "bad slot hex")]
                    | some slotBytes =>
                        match ← LeanCli.Ethereum.Mpt.verifyStorageProofIO
                            storageRootBytes (padTo32 slotBytes) nodes with
                        | .error e =>
                            slotResults := slotResults.push <| .obj #[
                              ("slot", .str slotHex),
                              ("error", .str e)]
                        | .ok value? =>
                            let value := value?.getD 0
                            let entry : LeanCli.Daemon.StateVault.StorageEntry := {
                              chainId, addr := address.toLower,
                              slot := slotHex.toLower,
                              blockNumber := head.blockNumber,
                              valueHex := natQuantityHex value,
                              tier }
                            let _ ← LeanCli.Daemon.State.withVault state
                              (fun h => LeanCli.Daemon.StateVault.putStorage h entry)
                            slotResults := slotResults.push <| .obj #[
                              ("slot", .str slotHex),
                              ("value", .str (natQuantityHex value)),
                              ("proven", .bool true)]
              pure <| .ok <| .obj #[
                ("address", .str address.toLower),
                ("chainId", .num (Int.ofNat chainId)),
                ("block", .num (Int.ofNat head.blockNumber)),
                ("stateRoot", .str head.stateRoot),
                ("headTier", .str head.tier.asString),
                ("tier", .str tier.asString),
                ("present", .bool verdict.isSome),
                ("balance", .str (natQuantityHex balance)),
                ("nonce", .num (Int.ofNat nonce)),
                ("codeHash", .str codeHash),
                ("slots", .arr slotResults)
              ]
      | _, _, _ =>
          pure (.error "eth_getProof result malformed: missing/invalid stateRoot, address, or accountProof")

/-- Every wallet-OWNED account address: stored EOA slots (daemon's
    active chain) and SPHINCS hybrid slots with a computed CREATE2
    counterfactual (their own chainId, skipped when the chain has no
    name mapping here). Mirrors `account.list`'s enumeration —
    read-only slot metadata, no key material. Deduped, lowercased. -/
def ownedAccounts : IO (Array (String × Option String)) := do
  let mut out : Array (String × Option String) := #[]
  let push (arr : Array (String × Option String)) (addr : String) (chain? : Option String) :
      Array (String × Option String) :=
    let lo := addr.toLower
    if arr.any (fun (a, c) => a == lo && c == chain?) then arr
    else arr.push (lo, chain?)
  let eoaNames ← LeanCli.Wallet.EoaStore.list
  for name in eoaNames do
    match ← LeanCli.Wallet.EoaStore.load name with
    | .ok record =>
        if !record.address.isEmpty then
          out := push out record.address none
    | .error _ => pure ()
  try
    let sphincsNames ← LeanCli.Wallet.SphincsHybridStore.listSlotNames
    for name in sphincsNames do
      match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
      | .ok rec =>
          match rec.smartAccountAddress with
          | some addr =>
              if !addr.isEmpty then
                if rec.chainId == 1 then
                  out := push out addr (some "mainnet")
                else if rec.chainId == 11155111 then
                  out := push out addr (some "sepolia")
                -- Unknown chainId: skip rather than prove on the wrong chain.
          | none => pure ()
      | .error _ => pure ()
  catch _ => pure ()
  pure out

/-- Pin every owned account at the current verified head (one head
    capture per chain, reused across that chain's accounts). "The state
    the user has should be state the wallet has proven" — called by the
    `vault.pinAccounts` RPC, the daemon's startup auto-pin task, and the
    TUI's slow refresh tier. Per-account failures are reported inline,
    never thrown. -/
def pinAllAccounts (cfg : Config) (state : LeanCli.Daemon.State.Shared) :
    IO Json := do
  let owned ← ownedAccounts
  let mut results : Array Json := #[]
  let mut okCount := 0
  -- (chainKey → resolved endpoint + chainId + captured head)
  let mut headCache :
    List (String × (LeanCli.RPC.Outbound.Endpoint × Nat ×
      LeanCli.Daemon.StateVault.HeaderEntry)) := []
  for (addr, chain?) in owned do
    let key := chain?.getD "@default"
    let mut ctx? : Option (LeanCli.RPC.Outbound.Endpoint × Nat ×
      LeanCli.Daemon.StateVault.HeaderEntry) := none
    match headCache.find? (fun (k, _) => k == key) with
    | some (_, c) => ctx? := some c
    | none =>
        match endpointForChain cfg chain? with
        | .error e =>
            results := results.push <| .obj #[
              ("address", .str addr), ("error", .str e)]
        | .ok ep =>
            let epHead ← applySafeNodeOverride state ep cfg.chainId
            let chainId := ep.chainId.getD cfg.chainId
            match ← captureHead cfg state epHead chainId with
            | .error e =>
                results := results.push <| .obj #[
                  ("address", .str addr),
                  ("error", .str s!"head capture failed: {e}")]
            | .ok head =>
                headCache := (key, (ep, chainId, head)) :: headCache
                ctx? := some (ep, chainId, head)
    match ctx? with
    | none => pure ()
    | some (ep, chainId, head) =>
        match ← pinAddress cfg state ep chainId head addr #[] with
        | .ok j =>
            okCount := okCount + 1
            results := results.push j
        | .error e =>
            results := results.push <| .obj #[
              ("address", .str addr), ("error", .str e)]
  pure <| .obj #[
    ("pinned", .num (Int.ofNat okCount)),
    ("total", .num (Int.ofNat owned.size)),
    ("accounts", .arr results)
  ]

/-- Handle every `vault.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (_notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "vault.status" =>
      let enabled := (← state.get).vault.isSome
      let counts? ← LeanCli.Daemon.State.withVault state
        (fun h => LeanCli.Daemon.StateVault.status h)
      let countsJson : Array (String × Json) :=
        match counts? with
        | some counts => counts.map (fun (t, n) => (t, Json.num (Int.ofNat n)))
        | none => #[]
      -- Latest pinned head for the requested (or default) chain, so the
      -- TUI's vault tile can render "head #N (tier)" from one cheap
      -- local read. `.null` when nothing is pinned yet.
      let chain? := getField "chain" req.params >>= asString
      let chainId :=
        match endpointForChain cfg chain? with
        | .ok ep => ep.chainId.getD cfg.chainId
        | .error _ => cfg.chainId
      let head? ← LeanCli.Daemon.State.withVault state
        (fun h => LeanCli.Daemon.StateVault.latestHeader h chainId)
      let headJson : Json :=
        match head? with
        | some (some hd) => hd.toJson
        | _ => .null
      pure <| .ok <| .obj #[
        ("enabled", .bool enabled),
        ("path", .str (← LeanCli.Daemon.StateVault.defaultPath)),
        ("backend", .str (← LeanCli.Daemon.State.getReadBackend state).asString),
        ("chainId", .num (Int.ofNat chainId)),
        ("head", headJson),
        ("counts", .obj countsJson)
      ]

  | "vault.captureHead" =>
      if (← state.get).vault.isNone then
        return .error vaultDisabled
      let chain? := getField "chain" req.params >>= asString
      match endpointForChain cfg chain? with
      | .error err =>
          pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
      | .ok ep =>
          let ep ← applySafeNodeOverride state ep cfg.chainId
          let chainId := ep.chainId.getD cfg.chainId
          match ← captureHead cfg state ep chainId with
          | .ok entry => pure (.ok entry.toJson)
          | .error e => pure (.error (vaultFailed "head capture failed" e))

  | "vault.pin" =>
      if (← state.get).vault.isNone then
        return .error vaultDisabled
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanCli.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let chain? := getField "chain" req.params >>= asString
              match endpointForChain cfg chain? with
              | .error err =>
                  pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
              | .ok ep =>
                  let epHead ← applySafeNodeOverride state ep cfg.chainId
                  let chainId := ep.chainId.getD cfg.chainId
                  -- Optional storage slots (hex strings).
                  let slots : Array String :=
                    match getField "slots" req.params with
                    | some (.arr xs) => xs.filterMap asString
                    | _ => #[]
                  -- Verified head anchor, then the shared pin core.
                  match ← captureHead cfg state epHead chainId with
                  | .error e => pure (.error (vaultFailed "head capture failed" e))
                  | .ok head =>
                      match ← pinAddress cfg state ep chainId head address slots with
                      | .ok j => pure (.ok j)
                      | .error e => pure (.error (vaultFailed "pin failed" e))

  | "vault.pinAccounts" =>
      if (← state.get).vault.isNone then
        return .error vaultDisabled
      pure (.ok (← pinAllAccounts cfg state))

  | "vault.get" =>
      if (← state.get).vault.isNone then
        return .error vaultDisabled
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          let chain? := getField "chain" req.params >>= asString
          match endpointForChain cfg chain? with
          | .error err =>
              pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
          | .ok ep =>
              let chainId := ep.chainId.getD cfg.chainId
              let account? ← LeanCli.Daemon.State.withVault state
                (fun h => LeanCli.Daemon.StateVault.getAccountLatest h chainId address)
              let slots? ← LeanCli.Daemon.State.withVault state
                (fun h => LeanCli.Daemon.StateVault.listStorageLatest h chainId address)
              let header? ← do
                match account? with
                | some (some acct) =>
                    LeanCli.Daemon.State.withVault state
                      (fun h => LeanCli.Daemon.StateVault.getHeader h chainId acct.blockNumber)
                | _ => pure none
              let accountJson : Json :=
                match account? with
                | some (some acct) => acct.toJson
                | _ => .null
              let slotsJson : Array Json :=
                match slots? with
                | some entries => entries.map (fun e => e.toJson)
                | none => #[]
              let headerJson : Json :=
                match header? with
                | some (some hd) => hd.toJson
                | _ => .null
              -- "asOf" semantics are explicit: this is NEVER head state.
              pure <| .ok <| .obj #[
                ("address", .str address.toLower),
                ("chainId", .num (Int.ofNat chainId)),
                ("account", accountJson),
                ("slots", .arr slotsJson),
                ("header", headerJson),
                ("stale", .bool true)
              ]

  | "vault.tokens" =>
      if (← state.get).vault.isNone then
        return .error vaultDisabled
      let chain? := getField "chain" req.params >>= asString
      match endpointForChain cfg chain? with
      | .error err =>
          pure <| .error { code := -32021, message := "unknown chain", data := some (.str err) }
      | .ok ep =>
          let chainId := ep.chainId.getD cfg.chainId
          let rows? ← LeanCli.Daemon.State.withVault state
            (fun h => LeanCli.Daemon.StateVault.listTokenMeta h chainId)
          let rowsJson : Array Json :=
            match rows? with
            | some rows => rows.map (fun (addr, d, sym, tier) =>
                .obj #[
                  ("address", .str addr),
                  ("decimals", .num (Int.ofNat d)),
                  ("symbol", .str sym),
                  ("tier", .str tier.asString)])
            | none => #[]
          pure <| .ok <| .obj #[
            ("chainId", .num (Int.ofNat chainId)),
            ("tokens", .arr rowsJson)
          ]

  | _ => pure (.error methodNotFound)

end LeanCli.Daemon.Server.VaultRpc
