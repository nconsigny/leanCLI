import LeanKohaku.Daemon.Server.Core
import LeanKohaku.Daemon.Server.Helpers
import LeanKohaku.Daemon.Server.Endpoints
import LeanKohaku.Daemon.Server.Journal
import LeanKohaku.Clearsign.Bridge
import LeanKohaku.Crypto.Hex
import LeanKohaku.Daemon.PpDestinations
import LeanKohaku.Daemon.State
import LeanKohaku.Daemon.TokenMeta
import LeanKohaku.Encoding.Json
import LeanKohaku.Ethereum.Address
import LeanKohaku.Ethereum.Tx
import LeanKohaku.Keystore.Tpm2Runtime
import LeanKohaku.Privacy.Bridge
import LeanKohaku.RPC.Outbound
import LeanKohaku.RPC.Server
import LeanKohaku.Util.Units
import LeanKohaku.Wallet.EOA
import LeanKohaku.Wallet.EoaStore
import LeanKohaku.Wallet.Entropy
import LeanKohaku.Wallet.Mnemonic
import LeanKohaku.Wallet.PpSecretStore
import LeanKohaku.Wallet.RgSecretStore

/-!
# Daemon server: `shielded.*` RPC family

Privacy Pools + Railgun + Tornado Cash flows. Sixteen arms covering
deposit / withdraw / transfer for each shielded backend, plus the
common ping / balance / reveal / import / delete utilities.

Trust posture: shielded calldata is opaque to the network but the
daemon still decodes + simulates + confirms every produced tx through
the standard pre-sign pipeline at the TUI / SendRawFlow boundary.
"It's shielded" does not grant signing authority.
-/

namespace LeanKohaku.Daemon.Server.ShieldedRpc

open LeanKohaku.Encoding.Json
open LeanKohaku.RPC.Server
open LeanKohaku.Daemon.Server

private def ppSecretMissing : RpcError :=
  { code := -32021
    message := "no Privacy Pools secret stored — run 'kohaku shield <wallet> <eth>' to create one or 'kohaku shield import <mnemonic>' to restore"
    data := none }

/-- Forward a shielded RPC to the kohaku-bridge sidecar.

Privacy Pools v1 is **Sepolia-only** at the contract layer. Regardless
of the daemon's default chain (cfg.chainId), every shielded operation
targets the Sepolia deployment. This function:

* pins the policy check + sidecar env to Sepolia (chainId=11155111,
  cfg.chainEndpoints["sepolia"] for the RPC URL);
* falls back to cfg.rpcEndpoint when Sepolia isn't configured — the
  call will fail downstream with a chain-mismatch error, which is
  clearer than the policy-denial path it used to take.

The mnemonic is supplied by the caller (after decrypting the on-disk
secret slot); the env var fallback that used to live here is removed.
-/
private def shieldedBridgeCall (cfg : Config) (method : String) (params : Json)
    (ppMnemonic? : Option String) (_req : Request)
    (rgMnemonic? : Option String := none)
    (rgBundlerUrl? : Option String := none)
    (rgDelegatingKeyHex? : Option String := none)
    (rgSeedHex? : Option String := none) :
    IO (Except RpcError Json) := do
  let bridgeReq : LeanKohaku.Privacy.Bridge.Request :=
    { method := method, params := params, id := 0 }
  -- Privacy Pools v1 is Sepolia-only. Pin the policy chainId so the
  -- chain-aware policy's testnet branch fires regardless of what the
  -- daemon's default chain happens to be.
  let ppChainId : Nat := 11155111
  let allowed := LeanKohaku.Privacy.Bridge.policyAllows cfg.policy
    .configuredNode .direct bridgeReq (some ppChainId)
  if !allowed then
    pure <| .error
      { code := -32030
        message := "shielded surface denied by policy"
        data := some (.str ("policy denies " ++ method)) }
  else
    -- Pick the Sepolia endpoint, not cfg.rpcEndpoint. Without this the
    -- sidecar gets handed the mainnet URL when the daemon's default is
    -- mainnet, then the on-chain calls fail or hit the wrong contract.
    let ppEndpoint : LeanKohaku.RPC.Outbound.Endpoint :=
      match endpointForChain cfg (some "sepolia") with
      | .ok ep => ep
      | .error _ => cfg.rpcEndpoint
    let ppDir ← LeanKohaku.Wallet.PpSecretStore.storeDir
    try IO.FS.createDirAll ppDir catch _ => pure ()
    let statePath := (ppDir / "state.json").toString
    let storagePath := (ppDir / "storage.json").toString
    -- Railgun has its own encrypted secret store (`RgSecretStore`) and a
    -- separate on-disk storage file. The mnemonic isolation invariant
    -- (railgun secret never appears in PP method env, PP secret never
    -- appears in railgun method env) is enforced by conditionally
    -- emitting LEANKOHAKU_*_MNEMONIC env vars below.
    let rgDir ← LeanKohaku.Wallet.RgSecretStore.storeDir
    try IO.FS.createDirAll rgDir catch _ => pure ()
    let rgStoragePath := (rgDir / "storage.json").toString
    let baseEnv : Array (String × Option String) := #[
      ("LEANKOHAKU_RPC_URL", some ppEndpoint.url),
      ("LEANKOHAKU_CHAIN_ID", some (toString ppChainId)),
      ("LEANKOHAKU_PP_STATE_PATH", some statePath),
      ("LEANKOHAKU_PP_STORAGE_PATH", some storagePath),
      ("LEANKOHAKU_RG_STORAGE_PATH", some rgStoragePath)
    ]
    let env : Array (String × Option String) :=
      baseEnv
      ++ (match ppMnemonic? with
          | some m => #[("LEANKOHAKU_PP_MNEMONIC", some m)]
          | none   => #[])
      ++ (match rgMnemonic? with
          | some m => #[("LEANKOHAKU_RG_MNEMONIC", some m)]
          | none   => #[])
      ++ (match rgBundlerUrl? with
          | some u => #[("LEANKOHAKU_RG_BUNDLER_URL", some u)]
          | none   => #[])
      ++ (match rgDelegatingKeyHex? with
          | some k => #[("LEANKOHAKU_RG_DELEGATING_KEY", some k)]
          | none   => #[])
      ++ (match rgSeedHex? with
          | some s => #[("LEANKOHAKU_RG_SEED_HEX", some s)]
          | none   => #[])
    let resp ← LeanKohaku.Privacy.Bridge.callWithEnv bridgeReq env
    -- Propagate bridge errors as JSON-RPC errors instead of burying them
    -- inside a successful `{ok:false, error:…}` payload. Without this the
    -- TUI/CLI render the wrapper as a successful result and the user only
    -- learns the broadcast failed by reading the JSON — which is exactly
    -- the bug that surfaced with PP v1 `RelayFeeGreaterThanMax`. The
    -- success branch now hands callers the raw bridge result; callers
    -- that previously peeled `result` still work because they fall back
    -- to the top-level object.
    match resp with
    | .ok j => pure (.ok j)
    | .err code msg data =>
        pure <| .error { code := code, message := msg, data := data }
    | .crash stderr exitCode =>
        pure <| .error
          { code := -32603,
            message := s!"shielded bridge crashed (exit {exitCode})",
            data := some (.obj #[
              ("stderr", .str stderr),
              ("exitCode", .num (Int.ofNat exitCode.toNat))
            ]) }

/-- Load the on-disk PP secret if present, decrypt it with the supplied
    passphrase, and return the plaintext mnemonic. Returns `-32021` when
    no record exists, and `-32011` when decryption fails. -/
private def unlockPpSecret (passphrase : String) : IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
    pure (.error ppSecretMissing)
  else
    match ← LeanKohaku.Wallet.PpSecretStore.unlock passphrase with
    | .ok phrase => pure (.ok phrase)
    | .error err =>
        pure <| .error
          { code := -32011, message := "PP secret unlock failed", data := some (.str err) }

/-- Master-aware PP unlock. Prefers the wallet KEK when:
    (a) the daemon currently holds a master KEK in `DaemonState`,
    (b) the PP record carries a `masterWrap` field,
    (c) the caller did NOT supply an explicit `passphrase` parameter
    (an explicit per-PP passphrase wins so users can still override).

    Falls back to `unlockPpSecret` with the explicit (or empty) passphrase
    on miss. After a successful per-PP unlock with the master KEK loaded,
    attaches a `masterWrap` to the on-disk record so subsequent unlocks
    can come through the master path — same lazy-enrolment policy as
    EOA slots. -/
private def unlockPpSecretSmart (state : LeanKohaku.Daemon.State.Shared)
    (passphrase? : Option String) : IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
    pure (.error ppSecretMissing)
  else
    match passphrase? with
    | none =>
        match ← LeanKohaku.Daemon.State.getMasterKek? state with
        | none =>
            pure <| .error
              { code := -32011, message := "PP secret unlock failed",
                data := some (.str "no passphrase supplied and wallet master is locked") }
        | some slot =>
            match ← LeanKohaku.Wallet.PpSecretStore.unlockWithMaster slot.kek with
            | .ok phrase => pure (.ok phrase)
            | .error err =>
                pure <| .error
                  { code := -32011, message := "PP secret unlock failed",
                    data := some (.str err) }
    | some p =>
        match ← LeanKohaku.Wallet.PpSecretStore.unlock p with
        | .error err =>
            pure <| .error
              { code := -32011, message := "PP secret unlock failed",
                data := some (.str err) }
        | .ok phrase =>
            -- Lazy enrol the PP record into the master KEK when both
            -- credentials are present in this call. Best-effort; failure
            -- to attach must not fail the unlock.
            (do
              match ← LeanKohaku.Daemon.State.getMasterKek? state with
              | none => pure ()
              | some slot =>
                  -- Skip if already enrolled to avoid an extra disk write
                  -- on every PP-passphrase unlock.
                  match ← LeanKohaku.Wallet.PpSecretStore.unlockWithMaster slot.kek with
                  | .ok _ => pure ()
                  | .error _ =>
                      match ← LeanKohaku.Wallet.PpSecretStore.attachMasterWrap slot.kek phrase with
                      | .ok _ => pure ()
                      | .error _ => pure ())
            pure (.ok phrase)

/-- JSON-RPC error code for a missing Railgun secret on disk. Separate
    from `ppSecretMissing` so the CLI surfaces the right "no railgun
    secret" hint and so the lazy-init path can detect the specific
    missing-secret case without string matching. -/
private def rgSecretMissing : RpcError :=
  { code := -32023
    message := "no Railgun secret stored — run 'kohaku shield railgun <wallet> <eth>' to create one or 'kohaku shield railgun import <mnemonic>' to restore"
    data := none }

/-- Master-aware Railgun unlock. Mirror of `unlockPpSecretSmart` but
    reads from `RgSecretStore`. Returns `rgSecretMissing` (code -32023)
    when the file does not exist so callers can detect first-time setup
    and route to the lazy-init path. -/
private def unlockRgSecretSmart (state : LeanKohaku.Daemon.State.Shared)
    (passphrase? : Option String) : IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.RgSecretStore.existsOnDisk) then
    pure (.error rgSecretMissing)
  else
    match passphrase? with
    | none =>
        match ← LeanKohaku.Daemon.State.getMasterKek? state with
        | none =>
            pure <| .error
              { code := -32011, message := "Railgun secret unlock failed",
                data := some (.str "no passphrase supplied and wallet master is locked") }
        | some slot =>
            match ← LeanKohaku.Wallet.RgSecretStore.unlockWithMaster slot.kek with
            | .ok phrase => pure (.ok phrase)
            | .error err =>
                pure <| .error
                  { code := -32011, message := "Railgun secret unlock failed",
                    data := some (.str err) }
    | some p =>
        match ← LeanKohaku.Wallet.RgSecretStore.unlock p with
        | .error err =>
            pure <| .error
              { code := -32011, message := "Railgun secret unlock failed",
                data := some (.str err) }
        | .ok phrase =>
            -- Lazy-enrol into the wallet master KEK on per-secret unlock.
            (do
              match ← LeanKohaku.Daemon.State.getMasterKek? state with
              | none => pure ()
              | some slot =>
                  match ← LeanKohaku.Wallet.RgSecretStore.unlockWithMaster slot.kek with
                  | .ok _ => pure ()
                  | .error _ =>
                      match ← LeanKohaku.Wallet.RgSecretStore.attachMasterWrap slot.kek phrase with
                      | .ok _ => pure ()
                      | .error _ => pure ())
            pure (.ok phrase)

-- TODO(railgun): re-attach this docstring to its function (likely
-- `unlockOrLazyInitRgSecret`). It became orphaned during the
-- railgun-alpha-21 merge; Lean 4 rejects two consecutive `/-- -/`
-- docstrings with no declaration between them.
--   Unlock the Railgun secret if present, otherwise generate a fresh
--   BIP-39 mnemonic, persist it via `RgSecretStore.save`, enrol into
--   the wallet master KEK (best-effort), and return the plaintext
--   phrase. Mirrors the lazy-init in PP's `shielded.deposit` handler
--   but writes to the Railgun store. Used by `shielded.railgun.shield`
--   so first-time shielding into Railgun "just works" without a
--   separate setup step, while still keeping the Railgun spending
--   secret cryptographically isolated from the PP and EOA secrets.
/-- The Railgun keystore is rooted at the EOA's master BIP-39 seed.
    Railgun derives at its own BIP-32 paths (via
    `RailgunSigner.spendingKeyPath` / `viewingKeyPath`), disjoint from
    BIP-44 Ethereum, so the same seed root yields independent Railgun
    spending/viewing keys. One mnemonic on disk, one unlock surface.

    Returns the seed of the named wallet's currently-unlocked slot
    encoded as 0x-prefixed hex, ready to pass to the bridge as
    `LEANKOHAKU_RG_SEED_HEX`. Errors if the slot is locked. -/
private def rgSeedHexFromSlot
    (slot : LeanKohaku.Daemon.State.UnlockedSlot) : String :=
  -- Hex.encode emits an already-`0x`-prefixed string (`Crypto/Hex.lean`
  -- line 25), so we pass its output through verbatim. Double-prefixing
  -- here would produce `0x0x…` which the bridge's keystoreFromSeedHex
  -- rejects after stripping the leading `0x` once.
  LeanKohaku.Crypto.Hex.encode slot.seed

/-- Default-wallet variant of `rgSeedHexFromSlot`. Resolution order:

      1. `defaultAccountPathIO` (set by `kohaku wallet use <name>` or
         the `account.setDefault` RPC).
      2. If no default is set, fall back to the **single** currently
         unlocked slot in `state.unlocked`. This covers the common
         "I have one EOA, just unlocked it via master KEK" case
         without forcing the user to also run `wallet use`.

    Returns `-32013` if neither step yields a wallet, or `-32012`
    (slot locked) if the resolved name isn't in `state.unlocked`. -/
private def rgSeedHexFromDefault
    (state : LeanKohaku.Daemon.State.Shared) : IO (Except RpcError String) := do
  let defaultPath ← defaultAccountPathIO
  let defaultName? : Option String ← do
    if ← defaultPath.pathExists then
      let raw ← try IO.FS.readFile defaultPath catch _ => pure ""
      let trimmed := raw.trimAscii.toString
      pure (if trimmed.isEmpty then none else some trimmed)
    else pure none
  match defaultName? with
  | some name =>
      match ← unlockedSlot state name with
      | .error err => pure (.error err)
      | .ok slot => pure (.ok (rgSeedHexFromSlot slot))
  | none =>
      -- No default configured. If exactly one slot is currently
      -- unlocked, use it — that's the user's intent in the
      -- single-wallet / master-KEK-unlock-then-balance flow.
      let unlocked := (← state.get).unlocked
      match unlocked with
      | [slot] => pure (.ok (rgSeedHexFromSlot slot))
      | [] =>
          pure <| .error
            { code := -32013,
              message := "no default wallet set and no slot unlocked — unlock a wallet (`kohaku wallet unlock <name>`) or set a default (`kohaku wallet use <name>`)",
              data := none }
      | _ :: _ :: _ =>
          pure <| .error
            { code := -32013,
              message := "no default wallet set and multiple slots are unlocked — pick one with `kohaku wallet use <name>` or pass `name` explicitly to the RPC",
              data := none }

private def unlockOrCreateRgSecret
    (state : LeanKohaku.Daemon.State.Shared) (passphrase? : Option String) :
    IO (Except RpcError String) := do
  if !(← LeanKohaku.Wallet.RgSecretStore.existsOnDisk) then
    IO.eprintln "[shield-rg] no Railgun secret on disk; generating fresh 12-word mnemonic"
    try
      let m ← LeanKohaku.Wallet.Entropy.generateMnemonic 12
      let phrase := LeanKohaku.Wallet.Mnemonic.phrase m
      let pass ← match passphrase? with
        | some p => pure p
        | none =>
            -- Same throwaway-passphrase pattern as PP: the durable unlock
            -- path is the master-wrap attached immediately after save.
            let r ← LeanKohaku.Crypto.Random.getRandomBytes 32
            pure (LeanKohaku.Crypto.Hex.encode r)
      match ← LeanKohaku.Wallet.RgSecretStore.save pass phrase with
      | .error err =>
          pure (.error
            ({ code := -32022,
               message := "failed to persist generated Railgun secret",
               data := some (.str err) } : RpcError))
      | .ok _ =>
          (do
            match ← LeanKohaku.Daemon.State.getMasterKek? state with
            | none => pure ()
            | some s =>
                let _ ← LeanKohaku.Wallet.RgSecretStore.attachMasterWrap s.kek phrase
                pure ())
          IO.eprintln "[shield-rg] Railgun secret generated and persisted"
          pure (.ok phrase)
    catch e =>
      pure (.error
        ({ code := -32022,
           message := "failed to generate Railgun secret",
           data := some (.str e.toString) } : RpcError))
  else
    IO.eprintln "[shield-rg] decrypting stored Railgun secret"
    unlockRgSecretSmart state passphrase?


/-- Decode a single bridge-returned tx object `{to, data, value}`. The
    bridge serialises bigints as 0x-hex strings; `value` may be missing
    for zero-value calls. -/
private def parseBridgeTx (json : Json) :
    Except RpcError (String × LeanKohaku.Ethereum.Address.Address × Nat × ByteArray) := do
  let toStr ← match getField "to" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let toAddr ← match LeanKohaku.Ethereum.Address.fromHex toStr with
    | some a => .ok a
    | none => .error invalidParams
  let dataStr ← match getField "data" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let data ← match LeanKohaku.Crypto.Hex.decode dataStr with
    | some b => .ok b
    | none => .error invalidParams
  let value ← match getField "value" json with
    | none => .ok 0
    | some .null => .ok 0
    | some j =>
        match asString j with
        | some s =>
            match parseHexQuantity s with
            | some n => .ok n
            | none => .error invalidParams
        | none =>
            match asNat j with
            | some n => .ok n
            | none => .error invalidParams
  .ok (toStr, toAddr, value, data)

/-- Loop signing and broadcasting prepared bridge txns sequentially,
    incrementing the nonce locally. Returns an array of per-tx send
    results, or the first error. -/
private def signAndBroadcastBridgeTxns
    (cfg : Config) (slot : LeanKohaku.Daemon.State.UnlockedSlot)
    (privateKey : ByteArray) (txns : Array Json)
    (notify? : Option LeanKohaku.Keystore.Tpm2Runtime.Notifier := none)
    (via? : Option LeanKohaku.RPC.Outbound.VerifyVia := none)
    (actionTag : String := "shielded.deposit") :
    IO (Except RpcError (Array Json)) := do
  let baseNonceJson ← LeanKohaku.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint slot.address "pending" via?
  match baseNonceJson with
  | .error err =>
      pure <| .error { code := -32020, message := "chain RPC failed", data := some (.str err) }
  | .ok nj =>
      match jsonHexNat nj with
      | .error err => pure (.error err)
      | .ok baseNonce =>
          let mut results : Array Json := #[]
          let mut idx : Nat := 0
          for raw in txns do
            match parseBridgeTx raw with
            | .error err => return .error err
            | .ok (toStr, toAddr, value, data) =>
                match ← buildSignBroadcastTx cfg slot privateKey toStr toAddr value data (some (baseNonce + idx)) notify? via? with
                | .error err => return .error err
                | .ok j =>
                    -- Why: best-effort shielded.deposit journal entry per broadcast tx.
                    let getStr (k : String) : String :=
                      (getField k j >>= asString).getD ""
                    let txHash := getStr "txHash"
                    let dataHex := LeanKohaku.Crypto.Hex.encode data
                    let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                    let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                    let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                    if !txHash.isEmpty then
                      journalRecord slot.name slot.address toStr txHash dataHex actionTag
                        value (baseNonce + idx) cfg.chainId none status? block? gas?
                    results := results.push j
                    idx := idx + 1
          pure (.ok results)



/-- Handle every `shielded.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanKohaku.Daemon.State.Shared)
    (notify : LeanKohaku.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "shielded.ping" =>
      let resp ← LeanKohaku.Privacy.Bridge.ping
      pure <| .ok <| LeanKohaku.Privacy.Bridge.responseToJson resp
  | "eip712.decodeIntent" =>
      -- Why: same architecture as tx.decodeIntent — daemon prefetches token
      -- metadata for any addresses we can identify cheaply (sellToken/
      -- buyToken in CowSwap-style orders, token in Permit2 EIP-712), then
      -- forwards to the clearsign sidecar with a `tokenMetadata` map. The
      -- sidecar walks the descriptor against `message`.
      let chainIdParam :=
        ((getField "chainId" req.params) >>= asNat).getD cfg.chainId
      let messageObj := (getField "message" req.params).getD (.obj #[])
      -- Pull every address-shaped string out of the (top-level) message
      -- and prefetch metadata for it. This is cheap and covers the common
      -- token-bearing fields without descriptor-aware path resolution.
      let addrs : Array String :=
        match messageObj with
        | .obj fields =>
            fields.filterMap (fun (_, v) =>
              match v with
              | .str s =>
                  if s.startsWith "0x" && s.length = 42 then some s else none
              | _ => none)
        | _ => #[]
      let mut tmObj : Array (String × Json) := #[]
      let ep := chainEndpointFor cfg req.params chainIdParam
      for addr in addrs do
        match ← LeanKohaku.Daemon.TokenMeta.lookupOrFetch
            state cfg.policy ep chainIdParam addr with
        | some m =>
            tmObj := tmObj.push (addr.toLower,
              LeanKohaku.Daemon.TokenMeta.toJson m)
        | none => pure ()
      let augmented : Json :=
        match req.params with
        | .obj fields =>
            .obj (fields.filter (fun (k, _) => k != "tokenMetadata")
              ++ #[("tokenMetadata", .obj tmObj)])
        | other => other
      let resp ← LeanKohaku.Clearsign.Bridge.call
        { method := "eip712.decodeIntent", params := augmented, id := 0 }
      pure <| .ok <| LeanKohaku.Clearsign.Bridge.responseToJson resp
  | "shielded.balance" =>
      let passphrase? : Option String := getField "passphrase" req.params >>= asString
      match ← unlockPpSecretSmart state passphrase? with
      | .error err => pure (.error err)
      | .ok mnemonic =>
          shieldedBridgeCall cfg "shielded.balance" (.obj #[]) (some mnemonic) req
  | "shielded.railgun.balance" =>
      -- Read-only Railgun balance. Railgun keystore is rooted at the
      -- default EOA's BIP-39 seed (Railgun derives at its own BIP-32
      -- paths — disjoint from BIP-44 Ethereum — so the same seed root
      -- yields independent Railgun keys with no separate mnemonic on
      -- disk). The default wallet must currently be unlocked (master
      -- KEK / TPM / recent per-slot unlock). First call is slow
      -- (Subsquid sync + POI artifact fetch); cached runs are fast.
      -- Optional `name` param overrides the default wallet.
      let nameOverride? := getField "name" req.params >>= asString
      let seedHexE ← do
        match nameOverride? with
        | some n =>
            match ← unlockedSlot state n with
            | .error err => pure (Except.error err)
            | .ok slot => pure (Except.ok (rgSeedHexFromSlot slot))
        | none => rgSeedHexFromDefault state
      match seedHexE with
      | .error err => pure (.error err)
      | .ok seedHex =>
          shieldedBridgeCall cfg "shielded.railgun.balance" (.obj #[]) none req
            (rgSeedHex? := some seedHex)
  | "shielded.railgun.prepareShield" =>
      -- Preview: build unsigned shield txns. tokenAddress optional;
      -- absence ⇒ native ETH (plugin wraps to WETH internally). Same
      -- EOA-seed keystore source as balance.
      match paramString req.params "amountEth" with
      | .error err => pure (.error err)
      | .ok amountEth =>
          let tokenAddress? := getField "tokenAddress" req.params >>= asString
          let nameOverride? := getField "name" req.params >>= asString
          let seedHexE ← do
            match nameOverride? with
            | some n =>
                match ← unlockedSlot state n with
                | .error err => pure (Except.error err)
                | .ok slot => pure (Except.ok (rgSeedHexFromSlot slot))
            | none => rgSeedHexFromDefault state
          match seedHexE with
          | .error err => pure (.error err)
          | .ok seedHex =>
              let bridgeParams : Json := .obj <|
                #[("amountEth", .str amountEth)] ++
                (match tokenAddress? with
                  | some a => #[("tokenAddress", .str a)]
                  | none   => #[])
              shieldedBridgeCall cfg "shielded.railgun.prepareShield" bridgeParams none req
                (rgSeedHex? := some seedHex)
  | "shielded.railgun.shield" =>
      -- Composed: prepare + EOA-sign + broadcast. Mirrors shielded.deposit
      -- but uses the EOA's BIP-39 seed as the Railgun keystore root.
      -- Railgun derives at its own BIP-32 paths (disjoint from
      -- BIP-44 Ethereum), so the same seed root yields independent
      -- Railgun keys. One mnemonic on disk, one unlock surface — the
      -- EOA unlock already done by the caller (UnlockEoaStep in the
      -- TUI) is the *only* unlock this handler needs.
      match paramName req.params, paramString req.params "amountEth" with
      | .ok name, .ok amountEth =>
          let tokenAddress? := getField "tokenAddress" req.params >>= asString
          IO.eprintln s!"[shield-rg] shield: wallet={name} amountEth={amountEth}"
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              IO.eprintln s!"[shield-rg] unlocked slot {name} address={slot.address}"
              match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok privateKey =>
                  let seedHex := rgSeedHexFromSlot slot
                  let bridgeParams : Json := .obj <|
                    #[("amountEth", .str amountEth)] ++
                    (match tokenAddress? with
                      | some a => #[("tokenAddress", .str a)]
                      | none   => #[])
                  IO.eprintln "[shield-rg] calling bridge shielded.railgun.prepareShield (loads SDK, syncs from Subsquid; may take 30-60s on first run)"
                  match ← shieldedBridgeCall cfg "shielded.railgun.prepareShield"
                            bridgeParams none req
                            (rgSeedHex? := some seedHex) with
                      | .error err =>
                          IO.eprintln s!"[shield-rg] bridge prepare failed: {err.message}"
                          pure (.error err)
                      | .ok prepared =>
                          IO.eprintln "[shield-rg] bridge returned prepared shield; decoding txns"
                          let resultField :=
                            match getField "result" prepared with
                            | some r => r
                            | none => prepared
                          let txnsArr := getField "txns" resultField >>= asArray
                          match txnsArr with
                          | none =>
                              IO.eprintln "[shield-rg] bridge returned no txns array"
                              pure <| .error
                                { code := -32020,
                                  message := "bridge returned no txns",
                                  data := some prepared }
                          | some txns =>
                              IO.eprintln s!"[shield-rg] signing and broadcasting {txns.size} tx(s)"
                              -- Same Sepolia pinning rationale as shielded.deposit
                              -- (see comment there): without this, txns prepared
                              -- for chain 11155111 would be signed with
                              -- cfg.chainId if the daemon defaults to mainnet.
                              let cfgShield : Config :=
                                let sepEp := match endpointForChain cfg (some "sepolia") with
                                  | .ok ep => ep
                                  | .error _ => cfg.rpcEndpoint
                                { cfg with rpcEndpoint := sepEp, chainId := 11155111 }
                              match ← signAndBroadcastBridgeTxns cfgShield slot privateKey txns
                                       (some notify) (actionTag := "shielded.railgun.shield") with
                              | .error err =>
                                  IO.eprintln s!"[shield-rg] broadcast failed: {err.message}"
                                  pure (.error err)
                              | .ok sent =>
                                  IO.eprintln s!"[shield-rg] broadcast complete: {sent.size} tx(s) sent"
                                  pure <| .ok <| .obj #[
                                    ("prepared", prepared),
                                    ("sent", .arr sent)
                                  ]
      | _, _ => pure (.error invalidParams)
  | "shielded.railgun.unshield" =>
      -- Builds + relays the private op via an ERC-4337 bundler using an
      -- EIP-7702 delegated EOA. Native ETH is supported in alpha-21
      -- (unshield-as-WETH + withdraw tail call). The Railgun secret only
      -- is unlocked here; the delegating EOA private key is derived from
      -- the named slot.
      --
      -- 7702 detail: Railgun's paymaster only sponsors UserOps whose
      -- 7702 Authorization delegates to its hardcoded IMPL contract
      -- (0x304a…4b4c). The SDK signs and embeds this authorization
      -- inside every broadcast UserOp; no separate setup tx is needed.
      --
      -- Trust note: the EOA private key is passed to the sidecar via
      -- env for the duration of this call. Mitigation: short-lived
      -- sidecar process; user has already gone through ConfirmGate
      -- before this RPC is invoked.
      --
      -- Bundler URL resolution:
      --   1. LEANKOHAKU_RG_BUNDLER_URL (explicit override) — wins.
      --   2. CANDIDE_API_KEY in env → construct
      --      https://api.candide.dev/bundler/v3/sepolia/<key>.
      --      (Sepolia-pinned; mainnet would be /ethereum/.)
      -- Must serve EntryPoint 0.8 (railgun-rs target). Candide's
      -- multi-version endpoint serves 0.6/0.7/0.8/0.9 from the same URL.
      match paramName req.params, paramString req.params "recipient",
            paramString req.params "amountEth" with
      | .ok name, .ok recipient, .ok amountEth =>
          let tokenAddress? := getField "tokenAddress" req.params >>= asString
          let resolveBundlerUrl : IO (Option String) := do
            match ← IO.getEnv "LEANKOHAKU_RG_BUNDLER_URL" with
            | some u => pure (some u)
            | none =>
                match ← IO.getEnv "CANDIDE_API_KEY" with
                | some k => pure (some s!"https://api.candide.dev/bundler/v3/sepolia/{k}")
                | none   => pure none
          match ← resolveBundlerUrl with
          | none =>
              pure <| .error
                { code := -32024,
                  message := "no 4337 bundler configured — set LEANKOHAKU_RG_BUNDLER_URL or CANDIDE_API_KEY in daemon env (.env auto-loaded)",
                  data := none }
          | some bundlerUrl =>
              -- TEMP-TEST env override: if both LEANKOHAKU_RG_DELEGATING_KEY
              -- and LEANKOHAKU_RG_SEED_HEX are set, skip wallet-slot
              -- derivation entirely (test setup that uses an EOA outside
              -- the daemon's wallet store). The `name` param is still
              -- required by the call signature but ignored. REMOVE this
              -- branch before production.
              let envDelegatingKey? ← IO.getEnv "LEANKOHAKU_RG_DELEGATING_KEY"
              let envSeed? ← IO.getEnv "LEANKOHAKU_RG_SEED_HEX"
              match envDelegatingKey?, envSeed? with
              | some envKey, some envSeed =>
                  IO.eprintln s!"[shield-rg] TEMP-TEST: using LEANKOHAKU_RG_DELEGATING_KEY + LEANKOHAKU_RG_SEED_HEX from daemon env (wallet '{name}' ignored)"
                  let bridgeParams : Json := .obj <|
                    #[("recipient", .str recipient),
                      ("amountEth", .str amountEth)] ++
                    (match tokenAddress? with
                      | some a => #[("tokenAddress", .str a)]
                      | none   => #[])
                  shieldedBridgeCall cfg "shielded.railgun.unshield"
                    bridgeParams none req
                    (rgBundlerUrl? := some bundlerUrl)
                    (rgDelegatingKeyHex? := some envKey)
                    (rgSeedHex? := some envSeed)
              | _, _ =>
                  match ← unlockedSlot state name with
                  | .error err => pure (.error err)
                  | .ok slot =>
                      match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
                      | .error err =>
                          pure <| .error { invalidParams with data := some (.str err) }
                      | .ok privateKey =>
                          -- Hex.encode emits its own `0x` prefix.
                          let delegatingKeyHex := LeanKohaku.Crypto.Hex.encode privateKey
                          let seedHex := rgSeedHexFromSlot slot
                          let bridgeParams : Json := .obj <|
                            #[("recipient", .str recipient),
                              ("amountEth", .str amountEth)] ++
                            (match tokenAddress? with
                              | some a => #[("tokenAddress", .str a)]
                              | none   => #[])
                          shieldedBridgeCall cfg "shielded.railgun.unshield"
                            bridgeParams none req
                            (rgBundlerUrl? := some bundlerUrl)
                            (rgDelegatingKeyHex? := some delegatingKeyHex)
                            (rgSeedHex? := some seedHex)
      | _, _, _ => pure (.error invalidParams)
  | "shielded.railgun.transfer" =>
      -- Railgun-internal transfer (0zk → 0zk). ERC20-only at SDK level
      -- (tokenGuard). Bundler + 7702 details: see shielded.railgun.unshield.
      match paramName req.params, paramString req.params "recipient",
            paramString req.params "amountEth",
            paramString req.params "tokenAddress" with
      | .ok name, .ok recipient, .ok amountEth, .ok tokenAddress =>
          let resolveBundlerUrl : IO (Option String) := do
            match ← IO.getEnv "LEANKOHAKU_RG_BUNDLER_URL" with
            | some u => pure (some u)
            | none =>
                match ← IO.getEnv "CANDIDE_API_KEY" with
                | some k => pure (some s!"https://api.candide.dev/bundler/v3/sepolia/{k}")
                | none   => pure none
          match ← resolveBundlerUrl with
          | none =>
              pure <| .error
                { code := -32024,
                  message := "no 4337 bundler configured — set LEANKOHAKU_RG_BUNDLER_URL or CANDIDE_API_KEY in daemon env",
                  data := none }
          | some bundlerUrl =>
              match ← unlockedSlot state name with
              | .error err => pure (.error err)
              | .ok slot =>
                  match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      -- Hex.encode emits its own `0x` prefix.
                      let delegatingKeyHex := LeanKohaku.Crypto.Hex.encode privateKey
                      let seedHex := rgSeedHexFromSlot slot
                      shieldedBridgeCall cfg "shielded.railgun.transfer"
                        (.obj #[
                          ("recipient", .str recipient),
                          ("amountEth", .str amountEth),
                          ("tokenAddress", .str tokenAddress)
                        ]) none req
                        (rgBundlerUrl? := some bundlerUrl)
                        (rgDelegatingKeyHex? := some delegatingKeyHex)
                        (rgSeedHex? := some seedHex)
      | _, _, _, _ => pure (.error invalidParams)
  | "shielded.tornado.prepareDeposit" =>
      -- Tornado Cash deposit drafting (PR 2). The bridge sidecar
      -- generates the user's spending note + Pedersen-hashed
      -- commitment and returns `deposit(commitment)` calldata for
      -- the pool contract that matches `amountEth`. Fixed-denomination
      -- enforcement happens both here (sidecar validates) and at the
      -- Intent layer (`IntentParser.tornadoDeposit`). PR 2 ships a
      -- bridge stub that returns a structured "SDK not yet wired"
      -- error until the snarkjs + Baby Jubjub Pedersen layer lands.
      match paramString req.params "amountEth" with
      | .error err => pure (.error err)
      | .ok amountEth =>
          shieldedBridgeCall cfg "shielded.tornado.prepareDeposit"
            (.obj #[("amountEth", .str amountEth)]) none req
  | "shielded.tornado.prepareWithdraw" =>
      -- Tornado Cash withdraw drafting. Bridge sidecar consumes the
      -- user's saved deposit note + current pool merkle state and
      -- emits `withdraw(proof, root, nullifierHash, recipient,
      -- relayer, fee, refund)` calldata. Note + recipient are
      -- required; the bridge stub returns the same "not yet wired"
      -- error pending sidecar implementation.
      match paramString req.params "amountEth",
            paramString req.params "recipient",
            paramString req.params "note" with
      | .ok amountEth, .ok recipient, .ok note =>
          shieldedBridgeCall cfg "shielded.tornado.prepareWithdraw"
            (.obj #[
              ("amountEth", .str amountEth),
              ("recipient", .str recipient),
              ("note",      .str note)
            ]) none req
      | _, _, _ => pure (.error invalidParams)
  | "shielded.prepareDeposit" =>
      match paramString req.params "amountEth" with
      | .error err => pure (.error err)
      | .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← unlockPpSecretSmart state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.prepareDeposit"
                (.obj #[("amountEth", .str amountEth)]) (some mnemonic) req
  | "shielded.deposit" =>
      match paramName req.params, paramString req.params "amountEth" with
      | .ok name, .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          IO.eprintln s!"[shield] deposit: wallet={name} amountEth={amountEth}"
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              IO.eprintln s!"[shield] unlocked slot {name} address={slot.address}"
              match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok privateKey =>
                  let mnemonicE ← do
                    if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
                      -- First-time PP setup. Per kohaku SDK convention the
                      -- mnemonic is freshly generated locally. Save path
                      -- still wants a passphrase for the per-PP record; if
                      -- the user didn't supply one, fall back to a
                      -- one-time random throwaway and rely on `attachMasterWrap`
                      -- (called below) so unlock UX still routes through
                      -- the master KEK.
                      IO.eprintln "[shield] no PP secret on disk; generating fresh 12-word mnemonic"
                      try
                        let m ← LeanKohaku.Wallet.Entropy.generateMnemonic 12
                        let phrase := LeanKohaku.Wallet.Mnemonic.phrase m
                        let pass ← match passphrase? with
                          | some p => pure p
                          | none =>
                              -- 32-byte random hex. Never returned to the
                              -- user; the master-wrap attachment immediately
                              -- after `save` is the only durable unlock path.
                              let r ← LeanKohaku.Crypto.Random.getRandomBytes 32
                              pure (LeanKohaku.Crypto.Hex.encode r)
                        match ← LeanKohaku.Wallet.PpSecretStore.save pass phrase with
                        | .error err =>
                            pure (.error
                              ({ code := -32022,
                                 message := "failed to persist generated PP secret",
                                 data := some (.str err) } : RpcError))
                        | .ok _ =>
                            -- Best-effort enrol into the wallet master so
                            -- the throwaway passphrase (if used) is not
                            -- the only key in play.
                            (do
                              match ← LeanKohaku.Daemon.State.getMasterKek? state with
                              | none => pure ()
                              | some s =>
                                  let _ ← LeanKohaku.Wallet.PpSecretStore.attachMasterWrap s.kek phrase
                                  pure ())
                            IO.eprintln "[shield] PP secret generated and persisted"
                            pure (.ok phrase)
                      catch e =>
                        pure (.error
                          ({ code := -32022,
                             message := "failed to generate PP secret",
                             data := some (.str e.toString) } : RpcError))
                    else
                      IO.eprintln "[shield] decrypting stored PP secret"
                      unlockPpSecretSmart state passphrase?
                  match mnemonicE with
                  | .error err => pure (.error err)
                  | .ok mnemonic =>
                      IO.eprintln "[shield] calling bridge shielded.prepareDeposit (this loads the SDK and syncs PP state from chain; may take 30-60s on first run)"
                      match ← shieldedBridgeCall cfg "shielded.prepareDeposit"
                                (.obj #[("amountEth", .str amountEth)]) (some mnemonic) req with
                      | .error err =>
                          IO.eprintln s!"[shield] bridge prepare failed: {err.message}"
                          pure (.error err)
                      | .ok prepared =>
                          IO.eprintln "[shield] bridge returned prepared deposit; decoding txns"
                          let resultField :=
                            match getField "result" prepared with
                            | some r => r
                            | none => prepared
                          let txnsArr := getField "txns" resultField >>= asArray
                          match txnsArr with
                          | none =>
                              IO.eprintln "[shield] bridge returned no txns array"
                              pure <| .error
                                { code := -32020,
                                  message := "bridge returned no txns",
                                  data := some prepared }
                          | some txns =>
                              IO.eprintln s!"[shield] signing and broadcasting {txns.size} tx(s)"
                              -- Privacy Pools v1 is Sepolia-only. Pin
                              -- the broadcast cfg to the sepolia
                              -- endpoint + chainId regardless of the
                              -- daemon's default. Same reasoning as
                              -- shieldedBridgeCall (slice 31) — without
                              -- this, txns prepared for chain 11155111
                              -- got signed with cfg.chainId (mainnet)
                              -- and the broadcast surfaced as the
                              -- vague "chain RPC failed".
                              let cfgShield : Config :=
                                let sepEp := match endpointForChain cfg (some "sepolia") with
                                  | .ok ep => ep
                                  | .error _ => cfg.rpcEndpoint
                                { cfg with rpcEndpoint := sepEp, chainId := 11155111 }
                              match ← signAndBroadcastBridgeTxns cfgShield slot privateKey txns (some notify) with
                              | .error err =>
                                  IO.eprintln s!"[shield] broadcast failed: {err.message}"
                                  pure (.error err)
                              | .ok sent =>
                                  IO.eprintln s!"[shield] broadcast complete: {sent.size} tx(s) sent"
                                  pure <| .ok <| .obj #[
                                    ("prepared", prepared),
                                    ("sent", .arr sent)
                                  ]
      | _, _ => pure (.error invalidParams)
  | "shielded.prepareWithdraw" =>
      match paramString req.params "recipient", paramString req.params "amountEth" with
      | .ok recipient, .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← unlockPpSecretSmart state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.prepareWithdraw"
                (.obj #[("recipient", .str recipient), ("amountEth", .str amountEth)]) (some mnemonic) req
      | _, _ => pure (.error invalidParams)
  | "shielded.unshieldDrain" =>
      match paramString req.params "recipient", paramString req.params "amountEth" with
      | .ok recipient, .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← unlockPpSecretSmart state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              match ← shieldedBridgeCall cfg "shielded.unshieldDrain"
                (.obj #[("recipient", .str recipient), ("amountEth", .str amountEth)])
                (some mnemonic) req with
              | .error err => pure (.error err)
              | .ok j =>
                  -- Record the recipient locally so the wallets-hub 0-link
                  -- check still passes after we credit the address with a
                  -- PP withdrawal. PP v1 is Sepolia-only today; chainId is
                  -- pinned in `shieldedBridgeCall`. Best-effort: a failed
                  -- log write never overrides the bridge response. Bridge
                  -- errors (e.g. RelayFeeGreaterThanMax) now arrive via
                  -- `.error` above, so the `.ok` arm is the actual relay
                  -- success path.
                  LeanKohaku.Daemon.PpDestinations.append recipient 11155111 "shielded.unshieldDrain"
                  pure (.ok j)
      | _, _ => pure (.error invalidParams)
  | "daemon.ppDestinations.add" =>
      -- Why: the auto-record hook in `shielded.unshieldDrain` only
      -- catches unshields THIS daemon executed after the hook
      -- existed. For older unshields, or unshields done out-of-band,
      -- the user can attest manually so the wallets-hub still treats
      -- the resulting address as PP-funded. Semantics: caller is
      -- saying "I unshielded to this; trust me." We do not try to
      -- verify against on-chain state.
      match paramString req.params "address" with
      | .error err => pure (.error err)
      | .ok address =>
          match LeanKohaku.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let chainId := (getField "chainId" req.params >>= asNat).getD 11155111
              LeanKohaku.Daemon.PpDestinations.append address chainId "manual"
              pure <| .ok <| .obj #[
                ("ok", .bool true),
                ("address", .str address),
                ("chainId", .num (Int.ofNat chainId))
              ]
  | "daemon.ppDestinations.list" =>
      let entries ← LeanKohaku.Daemon.PpDestinations.list
      pure <| .ok <| .obj #[("entries", .arr entries)]
  | "shielded.reveal" =>
      let passphrase? : Option String := getField "passphrase" req.params >>= asString
      match ← unlockPpSecretSmart state passphrase? with
      | .error err => pure (.error err)
      | .ok mnemonic =>
          pure <| .ok <| .obj #[("mnemonic", .str mnemonic)]
  | "shielded.import" =>
      match paramString req.params "passphrase", paramString req.params "mnemonic" with
      | .ok passphrase, .ok mnemonic =>
          if (← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
            pure <| .error
              { code := -32023,
                message := "PP secret already stored — run 'kohaku shield delete' first",
                data := none }
          else
            match ← LeanKohaku.Wallet.PpSecretStore.save passphrase mnemonic with
            | .error err =>
                pure <| .error
                  { code := -32022, message := "failed to persist PP secret",
                    data := some (.str err) }
            | .ok _ =>
                pure <| .ok <| .obj #[("ok", .bool true)]
      | _, _ => pure (.error invalidParams)
  | "shielded.delete" =>
      match paramString req.params "passphrase" with
      | .error err => pure (.error err)
      | .ok passphrase =>
          if !(← LeanKohaku.Wallet.PpSecretStore.existsOnDisk) then
            pure (.error ppSecretMissing)
          else
            match ← LeanKohaku.Wallet.PpSecretStore.unlock passphrase with
            | .error err =>
                pure <| .error
                  { code := -32011, message := "PP secret unlock failed",
                    data := some (.str err) }
            | .ok _ =>
                LeanKohaku.Wallet.PpSecretStore.delete
                pure <| .ok <| .obj #[("ok", .bool true)]
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanKohaku.Daemon.Server.ShieldedRpc
