import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.Server.Journal
import LeanCli.Clearsign.Bridge
import LeanCli.Crypto.Hex
import LeanCli.Daemon.PpDestinations
import LeanCli.Daemon.State
import LeanCli.Daemon.TokenMeta
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Tx
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.Privacy.Bridge
import LeanCli.Privacy.NoteVault
import LeanCli.Ethereum.TornadoTailCalls
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Util.Units
import LeanCli.Wallet.EOA
import LeanCli.Wallet.Bip44
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.Entropy
import LeanCli.Wallet.Mnemonic
import LeanCli.Wallet.PpSecretStore
import LeanCli.Wallet.RgSecretStore

/-!
# Daemon server: `shielded.*` RPC family

Privacy Pools + Railgun + Tornado Cash flows. Sixteen arms covering
deposit / withdraw / transfer for each shielded backend, plus the
common ping / balance / reveal / import / delete utilities.

Trust posture: shielded calldata is opaque to the network but NOT to the
user signing it. The interactive surfaces gate every shielded operation
before any broadcast; "it's shielded" does not grant signing authority:

* Shields (deposit) — `shielded.prepareDeposit` / `shielded.railgun.prepareShield`
  return UNSIGNED `{to,value,data}` legs that the TUI routes through the
  standard pre-sign pipeline (decode → simulate → ConfirmGate → eoa.send),
  one leg at a time. See `ShieldFlow.tsx`.
* PP unshield — has no EOA signature (the relayer submits the ZK proof), so
  `shielded.quoteUnshield` builds the proof without broadcasting and returns
  the relayer's fee terms; the TUI confirms those before `shielded.unshieldDrain`
  relays. See `UnshieldConfirmGate` in `WalletUnshieldFlow.tsx`.
* Railgun unshield — signed inside the sidecar (upstream WASM limitation; see
  the `shielded.railgun.unshield` arm). Mitigated by the same TUI confirm gate
  before the RPC, not by daemon-local signing.

The one-shot composite `shielded.deposit` / `shielded.railgun.shield` RPCs
(prepare+sign+broadcast, NO daemon-side gate) are retained ONLY for the
headless CLI, where there is no interactive confirm surface — they are
marked ⚠ UNGATED at their arms and MUST NOT be called from interactive code.
-/

namespace LeanCli.Daemon.Server.ShieldedRpc

open LeanCli.Encoding.Json
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

private def ppSecretMissing : RpcError :=
  { code := -32021
    message := "no Privacy Pools secret stored — run 'leancli shield <wallet> <eth>' to create one or 'leancli shield import <mnemonic>' to restore"
    data := none }

/-- Forward a shielded RPC to the leancli-bridge sidecar.

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
  let bridgeReq : LeanCli.Privacy.Bridge.Request :=
    { method := method, params := params, id := 0 }
  -- Privacy Pools v1 is Sepolia-only. Pin the policy chainId so the
  -- chain-aware policy's testnet branch fires regardless of what the
  -- daemon's default chain happens to be.
  let ppChainId : Nat := 11155111
  -- The policy gate now lives inside `callGated` (invariant 5.7): a
  -- denied request returns `policyDenial` before the sidecar is spawned,
  -- so no shielded call can bypass the policy. The classification is
  -- `peer := .localNode`, `transport := .loopback` (the sidecar is a
  -- local Node child of the daemon), which `gateDecision` fixes.
  do
    -- Pick the Sepolia endpoint, not cfg.rpcEndpoint. Without this the
    -- sidecar gets handed the mainnet URL when the daemon's default is
    -- mainnet, then the on-chain calls fail or hit the wrong contract.
    let ppEndpoint : LeanCli.RPC.Outbound.Endpoint :=
      match endpointForChain cfg (some "sepolia") with
      | .ok ep => ep
      | .error _ => cfg.rpcEndpoint
    let ppDir ← LeanCli.Wallet.PpSecretStore.storeDir
    try IO.FS.createDirAll ppDir catch _ => pure ()
    let statePath := (ppDir / "state.json").toString
    let storagePath := (ppDir / "storage.json").toString
    -- Railgun has its own encrypted secret store (`RgSecretStore`) and a
    -- separate on-disk storage file. The mnemonic isolation invariant
    -- (railgun secret never appears in PP method env, PP secret never
    -- appears in railgun method env) is enforced by conditionally
    -- emitting LEANCLI_*_MNEMONIC env vars below.
    let rgDir ← LeanCli.Wallet.RgSecretStore.storeDir
    try IO.FS.createDirAll rgDir catch _ => pure ()
    let rgStoragePath := (rgDir / "storage.json").toString
    let baseEnv : Array (String × Option String) := #[
      ("LEANCLI_RPC_URL", some ppEndpoint.url),
      ("LEANCLI_CHAIN_ID", some (toString ppChainId)),
      ("LEANCLI_PP_STATE_PATH", some statePath),
      ("LEANCLI_PP_STORAGE_PATH", some storagePath),
      ("LEANCLI_RG_STORAGE_PATH", some rgStoragePath)
    ]
    let env : Array (String × Option String) :=
      baseEnv
      ++ (match ppMnemonic? with
          | some m => #[("LEANCLI_PP_MNEMONIC", some m)]
          | none   => #[])
      ++ (match rgMnemonic? with
          | some m => #[("LEANCLI_RG_MNEMONIC", some m)]
          | none   => #[])
      ++ (match rgBundlerUrl? with
          | some u => #[("LEANCLI_RG_BUNDLER_URL", some u)]
          | none   => #[])
      ++ (match rgDelegatingKeyHex? with
          | some k => #[("LEANCLI_RG_DELEGATING_KEY", some k)]
          | none   => #[])
      ++ (match rgSeedHex? with
          | some s => #[("LEANCLI_RG_SEED_HEX", some s)]
          | none   => #[])
    -- Route through the policy gate (invariant 5.7): denied requests
    -- return `policyDenial` before the sidecar is spawned.
    let resp ← LeanCli.Privacy.Bridge.callGated cfg.policy bridgeReq env
      (some ppChainId)
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
  if !(← LeanCli.Wallet.PpSecretStore.existsOnDisk) then
    pure (.error ppSecretMissing)
  else
    match ← LeanCli.Wallet.PpSecretStore.unlock passphrase with
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
private def unlockPpSecretSmart (state : LeanCli.Daemon.State.Shared)
    (passphrase? : Option String) : IO (Except RpcError String) := do
  if !(← LeanCli.Wallet.PpSecretStore.existsOnDisk) then
    pure (.error ppSecretMissing)
  else
    match passphrase? with
    | none =>
        match ← LeanCli.Daemon.State.getMasterKek? state with
        | none =>
            pure <| .error
              { code := -32011, message := "PP secret unlock failed",
                data := some (.str "no passphrase supplied and wallet master is locked") }
        | some slot =>
            match ← LeanCli.Wallet.PpSecretStore.unlockWithMaster slot.kek with
            | .ok phrase => pure (.ok phrase)
            | .error err =>
                pure <| .error
                  { code := -32011, message := "PP secret unlock failed",
                    data := some (.str err) }
    | some p =>
        match ← LeanCli.Wallet.PpSecretStore.unlock p with
        | .error err =>
            pure <| .error
              { code := -32011, message := "PP secret unlock failed",
                data := some (.str err) }
        | .ok phrase =>
            -- Lazy enrol the PP record into the master KEK when both
            -- credentials are present in this call. Best-effort; failure
            -- to attach must not fail the unlock.
            (do
              match ← LeanCli.Daemon.State.getMasterKek? state with
              | none => pure ()
              | some slot =>
                  -- Skip if already enrolled to avoid an extra disk write
                  -- on every PP-passphrase unlock.
                  match ← LeanCli.Wallet.PpSecretStore.unlockWithMaster slot.kek with
                  | .ok _ => pure ()
                  | .error _ =>
                      match ← LeanCli.Wallet.PpSecretStore.attachMasterWrap slot.kek phrase with
                      | .ok _ => pure ()
                      | .error _ => pure ())
            pure (.ok phrase)

/-- Ensure a Privacy Pools secret exists on disk and return its mnemonic.

    First-time path: no record on disk ⇒ generate a fresh 12-word mnemonic,
    persist it (under the caller-supplied passphrase, or a one-time random
    throwaway), and best-effort enrol it into the wallet master KEK so the
    durable unlock path goes through the master rather than the throwaway.
    Otherwise, decrypt and return the stored secret via `unlockPpSecretSmart`.

    Shared by the gated prepare entry (`shielded.prepareDeposit`) and the
    one-shot composite (`shielded.deposit`) so first-time users get the same
    setup behaviour regardless of which surface they enter through. Creating
    a PP keypair is setup, not a signing action — it precedes (and is
    independent of) the user's per-tx confirmation of the deposit calldata. -/
private def ensurePpSecretMnemonic (state : LeanCli.Daemon.State.Shared)
    (passphrase? : Option String) : IO (Except RpcError String) := do
  if (← LeanCli.Wallet.PpSecretStore.existsOnDisk) then
    IO.eprintln "[shield] decrypting stored PP secret"
    unlockPpSecretSmart state passphrase?
  else
    IO.eprintln "[shield] no PP secret on disk; generating fresh 12-word mnemonic"
    try
      let m ← LeanCli.Wallet.Entropy.generateMnemonic 12
      let phrase := LeanCli.Wallet.Mnemonic.phrase m
      let pass ← match passphrase? with
        | some p => pure p
        | none =>
            -- 32-byte random hex. Never returned to the user; the
            -- master-wrap attachment immediately after `save` is the only
            -- durable unlock path.
            let r ← LeanCli.Crypto.Random.getRandomBytes 32
            pure (LeanCli.Crypto.Hex.encode r)
      match ← LeanCli.Wallet.PpSecretStore.save pass phrase with
      | .error err =>
          pure (.error
            ({ code := -32022,
               message := "failed to persist generated PP secret",
               data := some (.str err) } : RpcError))
      | .ok _ =>
          -- Best-effort enrol into the wallet master so the throwaway
          -- passphrase (if used) is not the only key in play.
          (do
            match ← LeanCli.Daemon.State.getMasterKek? state with
            | none => pure ()
            | some s =>
                let _ ← LeanCli.Wallet.PpSecretStore.attachMasterWrap s.kek phrase
                pure ())
          IO.eprintln "[shield] PP secret generated and persisted"
          pure (.ok phrase)
    catch e =>
      pure (.error
        ({ code := -32022,
           message := "failed to generate PP secret",
           data := some (.str e.toString) } : RpcError))

/-- JSON-RPC error code for a missing Railgun secret on disk. Separate
    from `ppSecretMissing` so the CLI surfaces the right "no railgun
    secret" hint and so the lazy-init path can detect the specific
    missing-secret case without string matching. -/
private def rgSecretMissing : RpcError :=
  { code := -32023
    message := "no Railgun secret stored — run 'leancli shield railgun <wallet> <eth>' to create one or 'leancli shield railgun import <mnemonic>' to restore"
    data := none }

/-- Master-aware Railgun unlock. Mirror of `unlockPpSecretSmart` but
    reads from `RgSecretStore`. Returns `rgSecretMissing` (code -32023)
    when the file does not exist so callers can detect first-time setup
    and route to the lazy-init path. -/
private def unlockRgSecretSmart (state : LeanCli.Daemon.State.Shared)
    (passphrase? : Option String) : IO (Except RpcError String) := do
  if !(← LeanCli.Wallet.RgSecretStore.existsOnDisk) then
    pure (.error rgSecretMissing)
  else
    match passphrase? with
    | none =>
        match ← LeanCli.Daemon.State.getMasterKek? state with
        | none =>
            pure <| .error
              { code := -32011, message := "Railgun secret unlock failed",
                data := some (.str "no passphrase supplied and wallet master is locked") }
        | some slot =>
            match ← LeanCli.Wallet.RgSecretStore.unlockWithMaster slot.kek with
            | .ok phrase => pure (.ok phrase)
            | .error err =>
                pure <| .error
                  { code := -32011, message := "Railgun secret unlock failed",
                    data := some (.str err) }
    | some p =>
        match ← LeanCli.Wallet.RgSecretStore.unlock p with
        | .error err =>
            pure <| .error
              { code := -32011, message := "Railgun secret unlock failed",
                data := some (.str err) }
        | .ok phrase =>
            -- Lazy-enrol into the wallet master KEK on per-secret unlock.
            (do
              match ← LeanCli.Daemon.State.getMasterKek? state with
              | none => pure ()
              | some slot =>
                  match ← LeanCli.Wallet.RgSecretStore.unlockWithMaster slot.kek with
                  | .ok _ => pure ()
                  | .error _ =>
                      match ← LeanCli.Wallet.RgSecretStore.attachMasterWrap slot.kek phrase with
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
    `LEANCLI_RG_SEED_HEX`. Errors if the slot is locked. -/
private def rgSeedHexFromSlot
    (slot : LeanCli.Daemon.State.UnlockedSlot) : String :=
  -- Hex.encode emits an already-`0x`-prefixed string (`Crypto/Hex.lean`
  -- line 25), so we pass its output through verbatim. Double-prefixing
  -- here would produce `0x0x…` which the bridge's keystoreFromSeedHex
  -- rejects after stripping the leading `0x` once.
  LeanCli.Crypto.Hex.encode slot.seed

/-- Default-wallet variant of `rgSeedHexFromSlot`. Resolution order:

      1. `defaultAccountPathIO` (set by `leancli wallet use <name>` or
         the `account.setDefault` RPC).
      2. If no default is set, fall back to the **single** currently
         unlocked slot in `state.unlocked`. This covers the common
         "I have one EOA, just unlocked it via master KEK" case
         without forcing the user to also run `wallet use`.

    Returns `-32013` if neither step yields a wallet, or `-32012`
    (slot locked) if the resolved name isn't in `state.unlocked`. -/
private def rgSlotFromDefault
    (state : LeanCli.Daemon.State.Shared) :
    IO (Except RpcError LeanCli.Daemon.State.UnlockedSlot) := do
  let defaultPath ← defaultAccountPathIO
  let defaultName? : Option String ← do
    if ← defaultPath.pathExists then
      let raw ← try IO.FS.readFile defaultPath catch _ => pure ""
      let trimmed := raw.trimAscii.toString
      pure (if trimmed.isEmpty then none else some trimmed)
    else pure none
  match defaultName? with
  | some name =>
      unlockedSlot state name
  | none =>
      -- No default configured. If exactly one slot is currently
      -- unlocked, use it — that's the user's intent in the
      -- single-wallet / master-KEK-unlock-then-balance flow.
      let unlocked := (← state.get).unlocked
      match unlocked with
      | [slot] => pure (.ok slot)
      | [] =>
          pure <| .error
            { code := -32013,
              message := "no default wallet set and no slot unlocked — unlock a wallet (`leancli wallet unlock <name>`) or set a default (`leancli wallet use <name>`)",
              data := none }
      | _ :: _ :: _ =>
          pure <| .error
            { code := -32013,
              message := "no default wallet set and multiple slots are unlocked — pick one with `leancli wallet use <name>` or pass `name` explicitly to the RPC",
              data := none }

private def rgSeedHexFromDefault
    (state : LeanCli.Daemon.State.Shared) : IO (Except RpcError String) := do
  match ← rgSlotFromDefault state with
  | .error err => pure (.error err)
  | .ok slot => pure (.ok (rgSeedHexFromSlot slot))

/-- Tornado on-disk state dir (per chain). Tornado has NO separate secret —
    its keystore is the EOA seed derived at disjoint BIP-32 paths (m/29795'/1'),
    so only chain-indexer state (commitments, merkle leaves, which deposit
    indices are ours) lives here. -/
private def tornadoStoreDir : IO System.FilePath := do
  pure ((← LeanCli.Wallet.EoaStore.dataHome) / "leancli" / "tc")

/-- Resolve the tornado chainId: explicit `chainId` param, else the daemon
    default. Tornado Cash is deployed on mainnet (1) and Sepolia (11155111). -/
private def resolveTornadoChain (cfg : Config) (params : Json) : Except RpcError Nat :=
  let cid := ((getField "chainId" params) >>= asNat).getD cfg.chainId
  if cid = 1 || cid = 11155111 then .ok cid
  else .error
    { code := -32602,
      message := s!"tornado cash is not deployed on chainId {cid} (supported: 1, 11155111)",
      data := none }

/-- Resolve the EOA seed hex backing the tornado keystore. Optional `name`
    param selects a specific unlocked slot; otherwise the default wallet. The
    seed is chain-independent; the SDK derives tornado-specific keys under its
    own BIP-32 root, disjoint from BIP-44 and from Railgun's paths. -/
private def tornadoSlot (state : LeanCli.Daemon.State.Shared) (params : Json) :
    IO (Except RpcError LeanCli.Daemon.State.UnlockedSlot) := do
  match getField "name" params >>= asString with
  | some n => unlockedSlot state n
  | none => rgSlotFromDefault state

private def tornadoSeedHex (state : LeanCli.Daemon.State.Shared) (params : Json) :
    IO (Except RpcError String) := do
  match ← tornadoSlot state params with
  | .error err => pure (.error err)
  | .ok slot => pure (.ok (rgSeedHexFromSlot slot))

/-- Resolve a Tornado withdrawal recipient to a BIP-44 path owned by the
    selected wallet. The request never supplies the path: the daemon reads it
    from EoaStore, then re-derives the address from the unlocked seed before
    allowing the sidecar to construct an EIP-7702 delegation. -/
private def tornadoRecipientDerivationPath
    (slot : LeanCli.Daemon.State.UnlockedSlot) (recipient : String) :
    IO (Except RpcError String) := do
  match ← loadRecord slot.name with
  | .error err => pure (.error err)
  | .ok record =>
      let target := recipient.toLower
      match (recordAccounts record).find? (fun account => account.address.toLower = target) with
      | none =>
          pure <| .error
            { code := -32602,
              message := "tornado withdrawal recipient must be an account derived from the selected wallet",
              data := some (.str recipient) }
      | some account =>
          match ← deriveAddressFromSeed slot.seed account.path with
          | .error err =>
              pure <| .error
                { code := -32602,
                  message := "stored tornado recipient derivation path is invalid",
                  data := some (.str err) }
          | .ok derived =>
              if derived.toLower = target then
                pure (.ok account.path)
              else
                pure <| .error
                  { code := -32602,
                    message := "stored tornado recipient does not match its wallet derivation path",
                    data := some (.str recipient) }

/-- Validate one `tailCalls` entry ({to, data, valueWei}) with the same
    predicates the CLI's `--tail-calls` parser used — the daemon does not
    trust its callers — and return the sanitized object to forward. -/
private def tornadoTailCallJson (i : Nat) (entry : Json) : Except RpcError Json :=
  let bad (msg : String) : Except RpcError Json :=
    .error { code := -32602, message := s!"invalid tailCalls[{i}]: {msg}", data := none }
  match getField "to" entry >>= asString with
  | none => bad "missing target address"
  | some to =>
      if !LeanCli.Ethereum.TornadoTailCalls.isHexAddress to then
        bad s!"target must be a 0x 20-byte address ({to})"
      else
        let data := (getField "data" entry >>= asString).getD "0x"
        if !LeanCli.Ethereum.TornadoTailCalls.isHexBytes data then
          bad "calldata must be 0x-prefixed byte-aligned hex"
        else
          let valueRaw := (getField "valueWei" entry >>= asString).getD "0"
          match LeanCli.Ethereum.TornadoTailCalls.parseValueWei valueRaw with
          | none => bad s!"valueWei must be decimal or 0x-hex wei ({valueRaw})"
          | some v =>
              .ok (.obj #[
                ("to", .str to),
                ("data", .str data),
                ("valueWei", .str (toString v))
              ])

/-- Validate the optional `tailCalls` request param (paymaster withdrawals:
    user calls appended after the payout call). Returns the sanitized array;
    absent param ⇒ empty. -/
private def tornadoTailCallsParam (params : Json) : Except RpcError (Array Json) :=
  match getField "tailCalls" params with
  | none => .ok #[]
  | some j =>
      match asArray j with
      | none => .error { code := -32602, message := "tailCalls must be an array", data := none }
      | some entries =>
          let rec go (i : Nat) (rest : List Json) (acc : Array Json) :
              Except RpcError (Array Json) :=
            match rest with
            | [] => .ok acc
            | e :: rest =>
                match tornadoTailCallJson i e with
                | .error err => .error err
                | .ok v => go (i + 1) rest (acc.push v)
          go 0 entries.toList #[]

/-- Forward a `shielded.tornado.*` method to the bridge. Unlike Privacy Pools
    (Sepolia-pinned), tornado runs on the caller-selected chain: the RPC
    endpoint, the LEANCLI_CHAIN_ID env, and the policy chainId all track
    `chainId`. The keystore is the EOA seed (`tcSeedHex`); state persists per
    chain under `tornadoStoreDir`. Routes through `callGated` (invariant 5.7):
    tornado withdrawals are classified `shieldedBroadcast`, so strict policy
    denies them on mainnet exactly like PP/railgun (mainnet needs tor/permissive). -/
private def tornadoBridgeCall (cfg : Config) (method : String) (params : Json)
    (chainId : Nat) (tcSeedHex : String) (_req : Request) :
    IO (Except RpcError Json) := do
  let bridgeReq : LeanCli.Privacy.Bridge.Request :=
    { method := method, params := params, id := 0 }
  let ep := chainEndpointFor cfg params chainId
  let tcDir ← tornadoStoreDir
  try IO.FS.createDirAll tcDir catch _ => pure ()
  let storagePath := (tcDir / s!"storage-{chainId}.json").toString
  let baseEnv : Array (String × Option String) := #[
    ("LEANCLI_RPC_URL", some ep.url),
    ("LEANCLI_CHAIN_ID", some (toString chainId)),
    ("LEANCLI_TC_STORAGE_PATH", some storagePath),
    ("LEANCLI_TC_SEED_HEX", some tcSeedHex)
  ]
  let env : Array (String × Option String) ←
    (match ← IO.getEnv "LEANCLI_TC_BUNDLER_URL" with
     | some u => pure (baseEnv ++ #[("LEANCLI_TC_BUNDLER_URL", some u)])
     | none   => pure baseEnv)
  let resp ← LeanCli.Privacy.Bridge.callGated cfg.policy bridgeReq env (some chainId)
  match resp with
  | .ok j => pure (.ok j)
  | .err code msg data =>
      pure <| .error { code := code, message := msg, data := data }
  | .crash stderr exitCode =>
      pure <| .error
        { code := -32603,
          message := s!"tornado bridge crashed (exit {exitCode})",
          data := some (.obj #[
            ("stderr", .str stderr),
            ("exitCode", .num (Int.ofNat exitCode.toNat))
          ]) }

/-- Defense in depth for `shielded.tornado.vault.import`: the untrusted sidecar
    is documented never to return raw note secrets, but the daemon forwards its
    `verifyNotes` result verbatim, so a sidecar regression must not be able to
    re-open that leak. Strip any `secrets` field from every note object in the
    result before it leaves the daemon. -/
private def scrubNoteSecrets (j : Json) : Json :=
  let stripSecrets (note : Json) : Json :=
    match note with
    | .obj fields => .obj (fields.filter (fun (k, _) => k != "secrets"))
    | other => other
  match j with
  | .obj fields =>
      .obj (fields.map (fun (k, v) =>
        if k == "notes" then
          match v with
          | .arr items => (k, .arr (items.map stripSecrets))
          | other => (k, other)
        else (k, v)))
  | other => other

private def unlockOrCreateRgSecret
    (state : LeanCli.Daemon.State.Shared) (passphrase? : Option String) :
    IO (Except RpcError String) := do
  if !(← LeanCli.Wallet.RgSecretStore.existsOnDisk) then
    IO.eprintln "[shield-rg] no Railgun secret on disk; generating fresh 12-word mnemonic"
    try
      let m ← LeanCli.Wallet.Entropy.generateMnemonic 12
      let phrase := LeanCli.Wallet.Mnemonic.phrase m
      let pass ← match passphrase? with
        | some p => pure p
        | none =>
            -- Same throwaway-passphrase pattern as PP: the durable unlock
            -- path is the master-wrap attached immediately after save.
            let r ← LeanCli.Crypto.Random.getRandomBytes 32
            pure (LeanCli.Crypto.Hex.encode r)
      match ← LeanCli.Wallet.RgSecretStore.save pass phrase with
      | .error err =>
          pure (.error
            ({ code := -32022,
               message := "failed to persist generated Railgun secret",
               data := some (.str err) } : RpcError))
      | .ok _ =>
          (do
            match ← LeanCli.Daemon.State.getMasterKek? state with
            | none => pure ()
            | some s =>
                let _ ← LeanCli.Wallet.RgSecretStore.attachMasterWrap s.kek phrase
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
    Except RpcError (String × LeanCli.Ethereum.Address.Address × Nat × ByteArray) := do
  let toStr ← match getField "to" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let toAddr ← match LeanCli.Ethereum.Address.fromHex toStr with
    | some a => .ok a
    | none => .error invalidParams
  let dataStr ← match getField "data" json >>= asString with
    | some s => .ok s
    | none => .error invalidParams
  let data ← match LeanCli.Crypto.Hex.decode dataStr with
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
    (cfg : Config) (slot : LeanCli.Daemon.State.UnlockedSlot)
    (privateKey : ByteArray) (txns : Array Json)
    (notify? : Option LeanCli.Keystore.Tpm2Runtime.Notifier := none)
    (via? : Option LeanCli.RPC.Outbound.VerifyVia := none)
    (actionTag : String := "shielded.deposit") :
    IO (Except RpcError (Array Json)) := do
  let baseNonceJson ← LeanCli.RPC.Outbound.getTransactionCount cfg.policy cfg.rpcEndpoint slot.address "pending" via?
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
                    let dataHex := LeanCli.Crypto.Hex.encode data
                    let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                    let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                    let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                    if !txHash.isEmpty then
                      journalRecord slot.name slot.address toStr txHash dataHex actionTag
                        value (baseNonce + idx) cfg.chainId none status? block? gas?
                    results := results.push j
                    idx := idx + 1
          pure (.ok results)



/-- C2 gate. The composite `shielded.*` deposit/shield arms (`shielded.deposit`,
    `shielded.tornado.deposit`, `shielded.railgun.shield`) call the untrusted
    sidecar's `prepare*`, then sign and broadcast the returned `{to,value,data}`
    with NO decode / simulate / ConfirmGate and NO re-derivation of `value` or
    allow-listing of `to`. A malicious sidecar can therefore return
    `{to: attacker, value: <whole balance>}` and have it signed. These arms
    exist only for the headless CLI; every interactive/agent surface must use
    the `prepare*` arms and route each unsigned leg through the per-leg pre-sign
    gate. Require an explicit operator opt-in so a caller on the daemon socket
    (the TUI, the LLM agent, any UDS client) cannot reach the un-confirmed
    broadcast path by default. -/
private def ungatedShieldAllowed : IO Bool := do
  match ← IO.getEnv "LEANCLI_ALLOW_UNGATED_SHIELD" with
  | some v => pure (v.trimAscii.toString == "1")
  | none   => pure false

private def ungatedShieldDenied : RpcError :=
  { code := -32040,
    message := "ungated one-shot shield/deposit is disabled: it signs sidecar-returned calldata with no decode/simulate/confirm. Use the interactive prepare→confirm flow, or set LEANCLI_ALLOW_UNGATED_SHIELD=1 in the daemon env to allow the headless composite.",
    data := none }

/-- C3 gate. `shielded.railgun.unshield` / `shielded.railgun.transfer` are the
    ONLY signing surfaces that hand the raw EOA private key to an untrusted
    sidecar (`LEANCLI_RG_DELEGATING_KEY`), which then signs and broadcasts the
    4337 UserOp itself with no daemon re-verification — a malicious plugin
    could sign an attacker-controlled 7702 delegation or a full-balance
    transfer, and the pre-RPC TUI confirm of the display terms cannot constrain
    the bytes a key-holding sidecar actually signs. The proper fix requires the
    upstream SDK to expose an unsigned UserOp + hash for in-core signing (see
    the TODO in the arm). Until then, require an explicit operator opt-in so
    the raw key is never exported by default. -/
private def railgunInSidecarSigningAllowed : IO Bool := do
  match ← IO.getEnv "LEANCLI_ALLOW_RAILGUN_INSIDECAR_SIGNING" with
  | some v => pure (v.trimAscii.toString == "1")
  | none   => pure false

private def railgunInSidecarSigningDenied : RpcError :=
  { code := -32041,
    message := "railgun unshield/transfer is disabled: unlike every other signing surface it hands the raw EOA private key to the untrusted sidecar, which signs and broadcasts the 4337 UserOp itself with no daemon re-verification. Set LEANCLI_ALLOW_RAILGUN_INSIDECAR_SIGNING=1 in the daemon env to accept this risk.",
    data := none }

/-- Handle every `shielded.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "shielded.ping" =>
      let resp ← LeanCli.Privacy.Bridge.ping
      pure <| .ok <| LeanCli.Privacy.Bridge.responseToJson resp
  | "shielded.hasSecret" =>
      -- Read-only: does a Privacy Pools secret exist on disk? Lets the thin
      -- CLI decide whether to prompt for the shielded-balance passphrase
      -- without importing `LeanCli.Wallet.PpSecretStore` (CLI-isolation guard).
      let present ← LeanCli.Wallet.PpSecretStore.existsOnDisk
      pure <| .ok <| .obj #[("exists", .bool present)]
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
        match ← LeanCli.Daemon.TokenMeta.lookupOrFetch
            state cfg.policy ep chainIdParam addr with
        | some m =>
            tmObj := tmObj.push (addr.toLower,
              LeanCli.Daemon.TokenMeta.toJson m)
        | none => pure ()
      let augmented : Json :=
        match req.params with
        | .obj fields =>
            .obj (fields.filter (fun (k, _) => k != "tokenMetadata")
              ++ #[("tokenMetadata", .obj tmObj)])
        | other => other
      let resp ← LeanCli.Clearsign.Bridge.call
        { method := "eip712.decodeIntent", params := augmented, id := 0 }
      pure <| .ok <| LeanCli.Clearsign.Bridge.responseToJson resp
  | "shielded.balance" =>
      let passphrase? : Option String := getField "passphrase" req.params >>= asString
      match ← unlockPpSecretSmart state passphrase? with
      | .error err => pure (.error err)
      | .ok mnemonic =>
          shieldedBridgeCall cfg "shielded.balance" (.obj #[]) (some mnemonic) req
  | "shielded.maxUnshield" =>
      let passphrase? : Option String := getField "passphrase" req.params >>= asString
      match ← unlockPpSecretSmart state passphrase? with
      | .error err => pure (.error err)
      | .ok mnemonic =>
          shieldedBridgeCall cfg "shielded.maxUnshield" (.obj #[]) (some mnemonic) req
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
  | "shielded.railgun.maxUnshield" =>
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
          let bundlerUrl? ← do
            match ← IO.getEnv "LEANCLI_RG_BUNDLER_URL" with
            | some u => pure (some u)
            | none =>
                match ← IO.getEnv "CANDIDE_API_KEY" with
                | some k => pure (some s!"https://api.candide.dev/bundler/v3/sepolia/{k}")
                | none => pure none
          match bundlerUrl? with
          | none => pure <| .error {
              code := -32024
              message := "no 4337 bundler configured — cannot price Railgun max unshield"
              data := none
            }
          | some bundlerUrl =>
              let strict := ((getField "strict" req.params) >>= asBool).getD false
              let tokenAddress? := getField "tokenAddress" req.params >>= asString
              let bridgeParams : Json := .obj <|
                #[ ("strict", .bool strict) ] ++
                (match tokenAddress? with
                  | some address => #[("tokenAddress", .str address)]
                  | none => #[])
              shieldedBridgeCall cfg "shielded.railgun.maxUnshield"
                bridgeParams none req
                (rgBundlerUrl? := some bundlerUrl)
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
  | "shielded.railgun.shield" => do
      unless (← ungatedShieldAllowed) do return .error ungatedShieldDenied
      -- ⚠ UNGATED one-shot (see `shielded.deposit`): prepare + EOA-sign +
      -- broadcast in one RPC, no daemon-side decode/simulate/ConfirmGate.
      -- Retained for the headless CLI only. Interactive surfaces use
      -- `shielded.railgun.prepareShield` + the standard per-leg pre-sign gate.
      --
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
  | "shielded.railgun.unshield" => do
      unless (← railgunInSidecarSigningAllowed) do return .error railgunInSidecarSigningDenied
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
      -- ⚠ Trust note: UNLIKE every other signing surface, the EOA private
      -- key is passed INTO the sidecar (via env) and the UserOp is signed
      -- there, not by the verified core. This is forced by the upstream SDK:
      -- the `@kohaku-eth/railgun` WASM `prepareUserOp(...)` returns an opaque
      -- `SignableUserOperation` whose only method is `.sign(signer)` — it
      -- exposes no `userOpHash`, no unsigned UserOp, and no 7702-auth payload
      -- to sign externally, so the key cannot stay in the daemon.
      -- TODO(upstream): to make this daemon-local-signed, the SDK must expose
      --   (1) build-unsigned-UserOp, (2) getUserOpHash, (3) build-7702-auth,
      --   (4) submit-pre-signed-UserOp. Until then the in-repo mitigation is
      --   the TUI disclosure ConfirmGate (WalletUnshieldFlow's
      --   UnshieldConfirmGate) shown BEFORE this RPC + a short-lived sidecar.
      -- (PP unshield is NOT affected — its withdraw is a relayer-submitted
      -- proof with no EOA signature, gated by shielded.quoteUnshield.)
      --
      -- Bundler URL resolution:
      --   1. LEANCLI_RG_BUNDLER_URL (explicit override) — wins.
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
            match ← IO.getEnv "LEANCLI_RG_BUNDLER_URL" with
            | some u => pure (some u)
            | none =>
                match ← IO.getEnv "CANDIDE_API_KEY" with
                | some k => pure (some s!"https://api.candide.dev/bundler/v3/sepolia/{k}")
                | none   => pure none
          match ← resolveBundlerUrl with
          | none =>
              pure <| .error
                { code := -32024,
                  message := "no 4337 bundler configured — set LEANCLI_RG_BUNDLER_URL or CANDIDE_API_KEY in daemon env (.env auto-loaded)",
                  data := none }
          | some bundlerUrl =>
              -- TEMP-TEST env override: if both LEANCLI_RG_DELEGATING_KEY
              -- and LEANCLI_RG_SEED_HEX are set, skip wallet-slot
              -- derivation entirely (test setup that uses an EOA outside
              -- the daemon's wallet store). The `name` param is still
              -- required by the call signature but ignored. REMOVE this
              -- branch before production.
              let envDelegatingKey? ← IO.getEnv "LEANCLI_RG_DELEGATING_KEY"
              let envSeed? ← IO.getEnv "LEANCLI_RG_SEED_HEX"
              match envDelegatingKey?, envSeed? with
              | some envKey, some envSeed =>
                  IO.eprintln s!"[shield-rg] TEMP-TEST: using LEANCLI_RG_DELEGATING_KEY + LEANCLI_RG_SEED_HEX from daemon env (wallet '{name}' ignored)"
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
                          let delegatingKeyHex := LeanCli.Crypto.Hex.encode privateKey
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
  | "shielded.railgun.transfer" => do
      unless (← railgunInSidecarSigningAllowed) do return .error railgunInSidecarSigningDenied
      -- Railgun-internal transfer (0zk → 0zk). ERC20-only at SDK level
      -- (tokenGuard). Bundler + 7702 details: see shielded.railgun.unshield.
      match paramName req.params, paramString req.params "recipient",
            paramString req.params "amountEth",
            paramString req.params "tokenAddress" with
      | .ok name, .ok recipient, .ok amountEth, .ok tokenAddress =>
          let resolveBundlerUrl : IO (Option String) := do
            match ← IO.getEnv "LEANCLI_RG_BUNDLER_URL" with
            | some u => pure (some u)
            | none =>
                match ← IO.getEnv "CANDIDE_API_KEY" with
                | some k => pure (some s!"https://api.candide.dev/bundler/v3/sepolia/{k}")
                | none   => pure none
          match ← resolveBundlerUrl with
          | none =>
              pure <| .error
                { code := -32024,
                  message := "no 4337 bundler configured — set LEANCLI_RG_BUNDLER_URL or CANDIDE_API_KEY in daemon env",
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
                      let delegatingKeyHex := LeanCli.Crypto.Hex.encode privateKey
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
  | "shielded.tornado.balance" =>
      -- Read-only tornado balance for the selected chain. Keystore is the
      -- EOA seed (disjoint BIP-32 paths); optional `name` selects a slot.
      -- First call is slow (pool sync via saga CDN + chain tail); cached
      -- state persists per chain.
      match resolveTornadoChain cfg req.params with
      | .error err => pure (.error err)
      | .ok cid =>
          match ← tornadoSeedHex state req.params with
          | .error err => pure (.error err)
          | .ok seedHex =>
              tornadoBridgeCall cfg "shielded.tornado.balance"
                (.obj #[("chainId", .num (Int.ofNat cid))]) cid seedHex req
  | "shielded.tornado.notes" =>
      -- Per-note detail (pool, denomination, depositIndex, spendable/spent).
      -- Notes are identified by (pool, depositIndex) and recovered from the
      -- wallet seed — there are no note strings.
      match resolveTornadoChain cfg req.params with
      | .error err => pure (.error err)
      | .ok cid =>
          let includeSpent := ((getField "includeSpent" req.params) >>= asBool).getD false
          match ← tornadoSeedHex state req.params with
          | .error err => pure (.error err)
          | .ok seedHex =>
              tornadoBridgeCall cfg "shielded.tornado.notes"
                (.obj #[
                  ("chainId", .num (Int.ofNat cid)),
                  ("includeSpent", .bool includeSpent)
                ]) cid seedHex req
  | "shielded.tornado.maxUnshield" =>
      match resolveTornadoChain cfg req.params with
      | .error err => pure (.error err)
      | .ok cid =>
          match ← tornadoSeedHex state req.params with
          | .error err => pure (.error err)
          | .ok seedHex =>
              tornadoBridgeCall cfg "shielded.tornado.maxUnshield"
                (.obj #[("chainId", .num (Int.ofNat cid))]) cid seedHex req
  | "shielded.tornado.prepareDeposit" =>
      -- Tornado Cash deposit. The bridge derives the spending note secrets
      -- deterministically from the seed, Pedersen-hashes the commitment, and
      -- returns UNSIGNED `deposit(commitment)` legs (an N×0.1-ETH amount
      -- becomes N fixed-denomination legs). The TUI routes each leg through
      -- decode → simulate → ConfirmGate → eoa.send — no note string to save,
      -- the wallet seed recovers every note.
      match resolveTornadoChain cfg req.params, paramString req.params "amountEth" with
      | .error err, _ => pure (.error err)
      | _, .error err => pure (.error err)
      | .ok cid, .ok amountEth =>
          match ← tornadoSeedHex state req.params with
          | .error err => pure (.error err)
          | .ok seedHex =>
              tornadoBridgeCall cfg "shielded.tornado.prepareDeposit"
                (.obj #[
                  ("chainId", .num (Int.ofNat cid)),
                  ("amountEth", .str amountEth)
                ]) cid seedHex req
  | "shielded.tornado.quoteWithdraw" =>
      -- Quote a withdrawal WITHOUT broadcasting: returns the paymaster fee +
      -- net amount (paymaster mode) or note context (relayer mode) for the
      -- ConfirmGate. A groth16 proof authorizes the note spend; paymaster mode
      -- also builds a deterministic EIP-7702 authorization from the verified
      -- recipient path at execute time. Confirming the quoted terms is the
      -- pre-broadcast gate (mirrors PP quoteUnshield). `mode` defaults to
      -- "paymaster"; "relayer" is optional.
      match resolveTornadoChain cfg req.params,
            paramString req.params "amountEth",
            paramString req.params "recipient" with
      | .ok cid, .ok amountEth, .ok recipient =>
          let mode := ((getField "mode" req.params) >>= asString).getD "paymaster"
          -- Fail fast (before unlocking a slot or spawning the sidecar) on
          -- malformed tail calls; only the paymaster UserOp can carry them.
          match tornadoTailCallsParam req.params with
          | .error err => pure (.error err)
          | .ok tailCalls =>
              if mode != "paymaster" && !tailCalls.isEmpty then
                pure <| .error {
                  code := -32602
                  message := "tailCalls are only supported in paymaster mode"
                  data := none
                }
              else
              match ← tornadoSlot state req.params with
              | .error err => pure (.error err)
              | .ok slot =>
                  match ← tornadoRecipientDerivationPath slot recipient with
                  | .error err => pure (.error err)
                  | .ok recipientPath =>
                      tornadoBridgeCall cfg "shielded.tornado.quoteWithdraw"
                        (.obj (#[
                          ("chainId", .num (Int.ofNat cid)),
                          ("amountEth", .str amountEth),
                          ("recipient", .str recipient),
                          ("recipientDerivationPath", .str recipientPath),
                          ("mode", .str mode)
                        ] ++ (if tailCalls.isEmpty then #[]
                              else #[("tailCalls", .arr tailCalls)])))
                        cid (rgSeedHexFromSlot slot) req
      | _, _, _ => pure (.error invalidParams)
  | "shielded.tornado.executeWithdraw" =>
      -- Build the withdrawal proof and broadcast it (paymaster default, or
      -- relayer). Classified `shieldedBroadcast` (invariant 5.7), so strict
      -- policy denies it on mainnet. Runs after the ConfirmGate accepted the
      -- quoteWithdraw terms.
      match resolveTornadoChain cfg req.params,
            paramString req.params "amountEth",
            paramString req.params "recipient" with
      | .ok cid, .ok amountEth, .ok recipient =>
          let mode := ((getField "mode" req.params) >>= asString).getD "paymaster"
          match ← tornadoSlot state req.params with
          | .error err => pure (.error err)
          | .ok slot =>
              match tornadoTailCallsParam req.params with
              | .error err => pure (.error err)
              | .ok tailCalls =>
                  if mode != "paymaster" && !tailCalls.isEmpty then
                    pure <| .error {
                      code := -32602
                      message := "tailCalls are only supported in paymaster mode"
                      data := none
                    }
                  else
                  match ← tornadoRecipientDerivationPath slot recipient with
                  | .error err => pure (.error err)
                  | .ok recipientPath =>
                      -- H2: forward the user-confirmed fee ceiling (the quoted
                      -- paymasterFeeWei) so the sidecar aborts rather than paying an
                      -- inflated fee out of the recipient's proceeds. Optional and
                      -- backward-compatible: absent ⇒ no ceiling (legacy behaviour).
                      let maxFeeWei? := getField "maxFeeWei" req.params >>= asString
                      tornadoBridgeCall cfg "shielded.tornado.executeWithdraw"
                        (.obj (#[
                          ("chainId", .num (Int.ofNat cid)),
                          ("amountEth", .str amountEth),
                          ("recipient", .str recipient),
                          ("recipientDerivationPath", .str recipientPath),
                          ("mode", .str mode)
                        ] ++ (match maxFeeWei? with
                              | some w => #[("maxFeeWei", .str w)]
                              | none   => #[])
                          ++ (if tailCalls.isEmpty then #[]
                              else #[("tailCalls", .arr tailCalls)])))
                        cid (rgSeedHexFromSlot slot) req
      | _, _, _ => pure (.error invalidParams)
  | "shielded.tornado.vault.export" =>
      -- Password-gated note backup. Asks the sidecar to derive every note's
      -- secrets from the wallet seed (`shielded.tornado.exportNotes`), then
      -- seals the blob under a USER-chosen password (independent of the wallet
      -- master passphrase) via `NoteVault` before it touches disk. The plaintext
      -- secrets are never returned to the caller — only the file path + count.
      match resolveTornadoChain cfg req.params,
            paramString req.params "password",
            paramString req.params "path" with
      | .ok cid, .ok password, .ok path =>
          let includeSpent := ((getField "includeSpent" req.params) >>= asBool).getD true
          match ← tornadoSeedHex state req.params with
          | .error err => pure (.error err)
          | .ok seedHex =>
              match ← tornadoBridgeCall cfg "shielded.tornado.exportNotes"
                (.obj #[
                  ("chainId", .num (Int.ofNat cid)),
                  ("includeSpent", .bool includeSpent)
                ]) cid seedHex req with
              | .error err => pure (.error err)
              | .ok payload =>
                  match ← LeanCli.Privacy.NoteVault.sealVault password "tornado-notes" cid payload with
                  | .error err =>
                      pure (.error { code := -32603, message := s!"failed to seal note vault: {err}", data := none })
                  | .ok manifest =>
                      let count := ((getField "count" payload) >>= asNat).getD 0
                      try
                        IO.FS.writeFile path (compact manifest ++ "\n")
                        pure (.ok (.obj #[
                          ("ok", .bool true),
                          ("path", .str path),
                          ("chainId", .num (Int.ofNat cid)),
                          ("count", .num (Int.ofNat count))
                        ]))
                      catch e =>
                        pure (.error { code := -32603, message := s!"failed to write vault file: {e}", data := some (.str path) })
      | _, _, _ => pure (.error invalidParams)
  | "shielded.tornado.vault.import" =>
      -- Import a note-vault file: decrypt with the user password, then hand the
      -- note descriptors to the sidecar to re-derive each commitment from THIS
      -- wallet's seed and confirm ownership + current spent status
      -- (`shielded.tornado.verifyNotes`). Display-only: an imported note is
      -- never a signing input, so the daemon proves ownership before showing it
      -- as yours. Raw note secrets are never returned to the caller.
      match resolveTornadoChain cfg req.params,
            paramString req.params "password",
            paramString req.params "path" with
      | .ok cid, .ok password, .ok path =>
          match ← (do try pure (Except.ok (← IO.FS.readFile path))
                      catch e => pure (Except.error (toString e))) with
          | .error e =>
              pure (.error { code := -32602, message := s!"cannot read vault file: {e}", data := some (.str path) })
          | .ok text =>
              match parse text with
              | .error e => pure (.error { code := -32602, message := s!"vault file is not valid JSON: {e}", data := none })
              | .ok manifest =>
                  match ← LeanCli.Privacy.NoteVault.openVault password manifest with
                  | .error err =>
                      pure (.error { code := -32602, message := err, data := none })
                  | .ok payload =>
                      let notesArr := (getField "notes" payload).getD (.arr #[])
                      match ← tornadoSeedHex state req.params with
                      | .error err => pure (.error err)
                      | .ok seedHex =>
                          match ← tornadoBridgeCall cfg "shielded.tornado.verifyNotes"
                            (.obj #[
                              ("chainId", .num (Int.ofNat cid)),
                              ("notes", notesArr)
                            ]) cid seedHex req with
                          | .error err => pure (.error err)
                          | .ok result => pure (.ok (scrubNoteSecrets result))
      | _, _, _ => pure (.error invalidParams)
  | "shielded.tornado.deposit" => do
      unless (← ungatedShieldAllowed) do return .error ungatedShieldDenied
      -- ⚠ UNGATED one-shot headless composite (`leancli shield tornado …`):
      -- prepares the unsigned deposit legs, then EOA-signs + broadcasts each on
      -- the selected chain WITHOUT the interactive decode → simulate →
      -- ConfirmGate. Retained ONLY for the headless CLI (no confirm surface);
      -- interactive surfaces MUST use `shielded.tornado.prepareDeposit` and
      -- route each unsigned leg through the standard pre-sign gate. The
      -- signing wallet's seed also derives the tornado note secrets, so the
      -- notes are recoverable from the same wallet.
      match resolveTornadoChain cfg req.params, paramName req.params,
            paramString req.params "amountEth" with
      | .ok cid, .ok name, .ok amountEth =>
          IO.eprintln s!"[shield-tc] deposit: wallet={name} chain={cid} amountEth={amountEth}"
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match ← derivePrivateKeyFromSeed slot.seed slot.derivationPath with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok privateKey =>
                  let seedHex := rgSeedHexFromSlot slot
                  IO.eprintln "[shield-tc] calling bridge shielded.tornado.prepareDeposit (loads the SDK + syncs pool state; may take a while on first run)"
                  match ← tornadoBridgeCall cfg "shielded.tornado.prepareDeposit"
                            (.obj #[
                              ("chainId", .num (Int.ofNat cid)),
                              ("amountEth", .str amountEth)
                            ]) cid seedHex req with
                  | .error err =>
                      IO.eprintln s!"[shield-tc] bridge prepare failed: {err.message}"
                      pure (.error err)
                  | .ok prepared =>
                      let resultField := (getField "result" prepared).getD prepared
                      match getField "txns" resultField >>= asArray with
                      | none =>
                          pure <| .error
                            { code := -32020,
                              message := "tornado bridge returned no txns",
                              data := some prepared }
                      | some txns =>
                          IO.eprintln s!"[shield-tc] signing and broadcasting {txns.size} tx(s) on chain {cid}"
                          let cfgTc : Config :=
                            let ep := chainEndpointFor cfg req.params cid
                            { cfg with rpcEndpoint := ep, chainId := cid }
                          match ← signAndBroadcastBridgeTxns cfgTc slot privateKey txns (some notify) with
                          | .error err =>
                              IO.eprintln s!"[shield-tc] broadcast failed: {err.message}"
                              pure (.error err)
                          | .ok sent =>
                              pure <| .ok <| .obj #[
                                ("prepared", prepared),
                                ("sent", .arr sent)
                              ]
      | _, _, _ => pure (.error invalidParams)
  | "shielded.prepareDeposit" =>
      -- Gated shield entry: returns UNSIGNED deposit txns for the TUI to
      -- route through decode → simulate → ConfirmGate → eoa.send (one leg
      -- at a time). `ensurePpSecretMnemonic` mirrors the composite
      -- `shielded.deposit` first-run setup so a first-time user entering via
      -- the gated path still gets a generated + master-enrolled PP secret.
      match paramString req.params "amountEth" with
      | .error err => pure (.error err)
      | .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← ensurePpSecretMnemonic state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.prepareDeposit"
                (.obj #[("amountEth", .str amountEth)]) (some mnemonic) req
  | "shielded.deposit" => do
      unless (← ungatedShieldAllowed) do return .error ungatedShieldDenied
      -- ⚠ UNGATED one-shot: prepares + EOA-signs + broadcasts in a single
      -- RPC, WITHOUT the daemon running decode → simulate → ConfirmGate.
      -- Retained ONLY for the headless CLI forwarder (`leancli shield`),
      -- which has no interactive confirm surface; the caller is responsible
      -- for confirming intent. Interactive surfaces (TUI ShieldFlow, chat)
      -- MUST NOT call this — they use `shielded.prepareDeposit` and route
      -- each unsigned leg through the standard pre-sign gate instead.
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
                  match ← ensurePpSecretMnemonic state passphrase? with
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
  | "shielded.quoteUnshield" =>
      -- Pre-broadcast quote for the gated unshield flow: builds the
      -- withdrawal proof WITHOUT broadcasting and returns the relayer's fee
      -- terms (recipient/amount/feeBPS/gas) so the TUI can show a ConfirmGate
      -- before `shielded.unshieldDrain` actually relays. A PP v1 withdraw
      -- carries no EOA signature (the relayer submits the proof), so
      -- confirming these terms IS the pre-broadcast trust anchor — there is
      -- no daemon-local signature to gate. Read-only on-chain (no state
      -- change); the proof is discarded and rebuilt by the drain.
      match paramString req.params "recipient", paramString req.params "amountEth" with
      | .ok recipient, .ok amountEth =>
          let passphrase? : Option String := getField "passphrase" req.params >>= asString
          match ← unlockPpSecretSmart state passphrase? with
          | .error err => pure (.error err)
          | .ok mnemonic =>
              shieldedBridgeCall cfg "shielded.quoteUnshield"
                (.obj #[("recipient", .str recipient), ("amountEth", .str amountEth)])
                (some mnemonic) req
      | _, _ => pure (.error invalidParams)
  | "shielded.unshieldDrain" =>
      -- ⚠ Broadcasts via the relayer. The gated TUI path calls
      -- `shielded.quoteUnshield` first and only reaches here after the user
      -- confirms the quoted terms. (The headless CLI calls it directly —
      -- caller is responsible for confirming intent.)
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
                  LeanCli.Daemon.PpDestinations.append recipient 11155111 "shielded.unshieldDrain"
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
          match LeanCli.Ethereum.Address.fromHex address with
          | none => pure (.error invalidParams)
          | some _ =>
              let chainId := (getField "chainId" req.params >>= asNat).getD 11155111
              LeanCli.Daemon.PpDestinations.append address chainId "manual"
              pure <| .ok <| .obj #[
                ("ok", .bool true),
                ("address", .str address),
                ("chainId", .num (Int.ofNat chainId))
              ]
  | "daemon.ppDestinations.list" =>
      let entries ← LeanCli.Daemon.PpDestinations.list
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
          if (← LeanCli.Wallet.PpSecretStore.existsOnDisk) then
            pure <| .error
              { code := -32023,
                message := "PP secret already stored — run 'leancli shield delete' first",
                data := none }
          else
            match ← LeanCli.Wallet.PpSecretStore.save passphrase mnemonic with
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
          if !(← LeanCli.Wallet.PpSecretStore.existsOnDisk) then
            pure (.error ppSecretMissing)
          else
            match ← LeanCli.Wallet.PpSecretStore.unlock passphrase with
            | .error err =>
                pure <| .error
                  { code := -32011, message := "PP secret unlock failed",
                    data := some (.str err) }
            | .ok _ =>
                LeanCli.Wallet.PpSecretStore.delete
                pure <| .ok <| .obj #[("ok", .bool true)]
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.ShieldedRpc
