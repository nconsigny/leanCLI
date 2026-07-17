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

private def bytesToHex0x (b : ByteArray) : String :=
  "0x" ++ LeanCli.Crypto.Hex.encode b

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
      pure <| .ok <| .obj #[
        ("enabled", .bool enabled),
        ("path", .str (← LeanCli.Daemon.StateVault.defaultPath)),
        ("backend", .str (← LeanCli.Daemon.State.getReadBackend state).asString),
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
                  -- 1. Verified head anchor.
                  match ← captureHead cfg state epHead chainId with
                  | .error e => pure (.error (vaultFailed "head capture failed" e))
                  | .ok head =>
                      let blockHex := natQuantityHex head.blockNumber
                      -- 2. Proof from the UNTRUSTED direct RPC (via? = none:
                      -- the proof carries its own integrity, Lean checks it).
                      let slotJson : Array Json := slots.map (fun s => .str s)
                      match ← LeanCli.RPC.Outbound.getProof cfg.policy ep
                          address slotJson blockHex none with
                      | .error e =>
                          pure (.error (vaultFailed "eth_getProof failed" e))
                      | .ok proofJson =>
                          -- 3. Verify in Lean against the captured stateRoot.
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
                              | .error e =>
                                  pure (.error (vaultFailed "account proof rejected" e))
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
                                  -- 4. Storage-slot proofs against the PROVEN
                                  -- storageRoot (not the RPC's claimed one).
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
                              pure (.error (vaultFailed "eth_getProof result malformed"
                                "missing/invalid stateRoot, address, or accountProof"))

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
