import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Crypto.Hex
import LeanCli.Daemon.State
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Keystore.MasterKey
import LeanCli.Keystore.MasterPassphrase
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Server
import LeanCli.Wallet.EoaStore

/-!
# Daemon server: `wallet.*` RPC family

Master KEK lifecycle and verified-addresses enumeration. Seven arms:

  wallet.master.status       — Is a master KEK loaded?
  wallet.master.init         — Create a new master KEK
  wallet.master.bindTpm      — Optional TPM binding for the master KEK
  wallet.master.setTimeout   — Adjust the in-memory KEK timeout
  wallet.unlock              — Unlock a slot (master-first, fallback to per-slot)
  wallet.lock                — Lock all unlocked slots
  wallet.lean_verified_addresses
                             — Trusted-registry RPC: enumerate the daemon's
                               verified BIP-44 paths under the per-path cap

Trust model: this module touches secrets but does not sign — it stages
unlocked-slot state for downstream signing modules to consume.
-/

namespace LeanCli.Daemon.Server.WalletRpc

open LeanCli.Encoding.Json
open LeanCli.Keystore.Tpm2Runtime
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `wallet.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "wallet.master.status" =>
      -- Why: lightweight status probe used by CLI / TUI to decide whether
      -- to prompt for the master passphrase vs. fall back to per-slot
      -- unlock. Reads the manifest if present; lists EOAs by enrolment
      -- bucket so the front-end can surface "X slots not yet enrolled".
      let initialized ← LeanCli.Keystore.MasterPassphrase.existsOnDisk
      let tpmEnrolled ← LeanCli.Keystore.MasterKey.existsOnDisk
      let tpmHardwareReady ← LeanCli.Keystore.MasterKey.hardwareReady
      let manifest? ←
        if initialized then
          (do
            match ← LeanCli.Keystore.MasterPassphrase.loadManifest with
            | .ok m => pure (some m)
            | .error _ => pure none)
        else pure none
      let withTpm := match manifest? with
        | some m => m.tpmWrap.isSome
        | none => false
      let masterUnlocked := (← LeanCli.Daemon.State.getMasterKek? state).isSome
      let names ← LeanCli.Wallet.EoaStore.list
      let mut enrolled : Array Json := #[]
      let mut unenrolled : Array Json := #[]
      let mut custom : Array Json := #[]
      for name in names do
        match ← LeanCli.Wallet.EoaStore.load name with
        | .error _ => pure ()
        | .ok rec =>
            if rec.customPassphrase then
              custom := custom.push (.str name)
            else if rec.masterWrap.isSome then
              enrolled := enrolled.push (.str name)
            else
              unenrolled := unenrolled.push (.str name)
      let ttlMs : Nat := match manifest? with
        | some m => m.ttlMs
        | none => 0
      pure <| .ok <| .obj #[
        ("initialized", .bool initialized),
        ("withTpm", .bool withTpm),
        -- Why: split TPM state into "hardware reachable" vs "master key
        -- already bootstrapped". The CLI cares about hardware-ready at
        -- init time (offer PIN prompt) and enrolment at unlock time
        -- (route through the TPM path). `tpmAvailable` keeps the old
        -- name for back-compat with clients written against the
        -- previous schema.
        ("tpmHardwareReady", .bool tpmHardwareReady),
        ("tpmAvailable", .bool tpmEnrolled),
        ("masterUnlocked", .bool masterUnlocked),
        ("ttlMs", .num (Int.ofNat ttlMs)),
        ("enrolledEoas", .arr enrolled),
        ("unenrolledEoas", .arr unenrolled),
        ("customEoas", .arr custom)
      ]
  | "wallet.master.init" =>
      -- Why: bootstrap the master KEK manifest. Single-credential UX —
      -- callers always supply `passphrase` (the recovery / no-TPM fallback)
      -- and OPTIONALLY supply `masterPin`. Presence of a non-empty
      -- `masterPin` plus a usable TPM triggers a TPM envelope on the same
      -- KEK; absence is fine and yields a passphrase-only manifest. TPM
      -- failures during init are logged and reported but DO NOT fail the
      -- init — the passphrase wrap is always written.
      match paramString req.params "passphrase" with
      | .error err => pure (.error err)
      | .ok passphrase =>
          if (← LeanCli.Keystore.MasterPassphrase.existsOnDisk) then
            pure <| .error { code := -32030, message := "wallet master already initialized", data := none }
          else
            let timeoutMins : Nat := (getField "timeoutMins" req.params >>= asNat).getD 5
            let ttlMs : Nat := if timeoutMins == 0 then 0 else timeoutMins * 60000
            let masterPin? : Option String := getField "masterPin" req.params >>= asString
            let pinPresent : Bool := match masterPin? with
              | some p => !p.isEmpty
              | none => false
            -- Resolve a TPM key only when (a) caller supplied a PIN, AND
            -- (b) hardware looks usable. Both gates avoid running tpm2
            -- tools on hosts without /dev/tpm or tpm2-tools installed.
            let mut tpmKey? : Option ByteArray := none
            let mut tpmNote : Option String := none
            if pinPresent then
              if !(← LeanCli.Keystore.MasterKey.hardwareReady) then
                tpmNote := some "TPM hardware not available; falling back to passphrase-only"
              else
                let pin := masterPin?.getD ""
                let res ←
                  if ← LeanCli.Keystore.MasterKey.existsOnDisk then
                    LeanCli.Keystore.MasterKey.unsealMaster pin notify
                  else
                    match ← LeanCli.Keystore.MasterKey.bootstrap pin notify with
                    | .error e => pure (.error e)
                    | .ok _ => LeanCli.Keystore.MasterKey.unsealMaster pin notify
                match res with
                | .ok k => tpmKey? := some k
                | .error e => tpmNote := some s!"TPM bind failed: {e}"
            match ← LeanCli.Keystore.MasterPassphrase.buildManifest passphrase tpmKey? ttlMs (← IO.monoMsNow) with
            | .error err =>
                pure <| .error { code := -32031, message := "failed to build master manifest", data := some (.str err) }
            | .ok (manifest, kek) =>
                LeanCli.Keystore.MasterPassphrase.saveManifest manifest
                LeanCli.Daemon.State.unlockMaster state {
                  kek := kek,
                  unlockedAtMs := ← IO.monoMsNow,
                  ttlMs := manifest.ttlMs
                }
                let base : Array (String × Json) := #[
                  ("initialized", .bool true),
                  ("withTpm", .bool manifest.tpmWrap.isSome),
                  ("masterUnlocked", .bool true),
                  ("ttlMs", .num (Int.ofNat manifest.ttlMs))
                ]
                let fields : Array (String × Json) :=
                  match tpmNote with
                  | none => base
                  | some n => base.push ("note", .str n)
                pure <| .ok <| .obj fields
  | "wallet.unlock" =>
      -- Why: master-passphrase or TPM-PIN path. Either credential decrypts
      -- the wallet KEK; the KEK then unwraps every enrolled EOA slot in
      -- one shot. Slots with no `masterWrap` (legacy or custom) are
      -- reported as `skipped` so the front-end can re-prompt per-slot.
      if !(← LeanCli.Keystore.MasterPassphrase.existsOnDisk) then
        pure <| .error { code := -32032, message := "wallet master not initialized — run `wallet.master.init` first", data := none }
      else
        match ← LeanCli.Keystore.MasterPassphrase.loadManifest with
        | .error err =>
            pure <| .error { code := -32033, message := "master manifest is corrupt", data := some (.str err) }
        | .ok manifest =>
            let passphrase? : Option String := getField "passphrase" req.params >>= asString
            let masterPin? : Option String := getField "masterPin" req.params >>= asString
            let kekRes ←
              match passphrase?, masterPin? with
              | some p, _ =>
                  LeanCli.Keystore.MasterPassphrase.unlockWithPassphrase manifest p
              | none, some pin =>
                  if !manifest.tpmWrap.isSome then
                    pure (.error "this wallet manifest has no tpmWrap; use `passphrase` instead")
                  else
                    match ← LeanCli.Keystore.MasterKey.unsealMaster pin notify with
                    | .error e => pure (.error e)
                    | .ok tpmKey =>
                        LeanCli.Keystore.MasterPassphrase.unlockWithTpmKey manifest tpmKey
              | none, none =>
                  pure (.error "supply either `passphrase` or `masterPin`")
            match kekRes with
            | .error err =>
                pure <| .error { code := -32034, message := "wallet unlock failed", data := some (.str err) }
            | .ok kek =>
                let ttlMs := manifest.ttlMs
                LeanCli.Daemon.State.unlockMaster state {
                  kek := kek,
                  unlockedAtMs := ← IO.monoMsNow,
                  ttlMs := ttlMs
                }
                -- Iterate enrolled EOA slots; populate per-slot unlock state.
                let names ← LeanCli.Wallet.EoaStore.list
                let mut enrolled : Array Json := #[]
                let mut skipped : Array Json := #[]
                for name in names do
                  match ← LeanCli.Wallet.EoaStore.load name with
                  | .error e =>
                      skipped := skipped.push <| .obj #[
                        ("name", .str name), ("reason", .str e)]
                  | .ok rec =>
                      if rec.customPassphrase then
                        skipped := skipped.push <| .obj #[
                          ("name", .str name), ("reason", .str "custom-passphrase")]
                      else
                        match rec.masterWrap with
                        | none =>
                            skipped := skipped.push <| .obj #[
                              ("name", .str name), ("reason", .str "not-enrolled")]
                        | some w =>
                            match ← LeanCli.Keystore.MasterPassphrase.unwrapSlot
                                kek rec.name rec.derivationPath rec.address w with
                            | .error _ =>
                                -- Why: the verifier above already proved
                                -- the typed credential matches the manifest.
                                -- If `unwrapSlot` still fails, the slot's
                                -- `masterWrap` was made under a different
                                -- (now-discarded) KEK — usually because the
                                -- user wiped `wallet/master.json` and
                                -- re-init'd. Surface as `stale-wrap` with
                                -- a clear next-step hint; one
                                -- `leancli wallet enroll <name>` rewrites
                                -- the wrap under the current KEK.
                                skipped := skipped.push <| .obj #[
                                  ("name", .str name),
                                  ("reason", .str "stale-wrap"),
                                  ("hint", .str s!"run `leancli wallet enroll {name}` to re-enrol this slot under the current master KEK")]
                            | .ok seed =>
                                LeanCli.Daemon.State.unlock state {
                                  name := rec.name,
                                  seed := seed,
                                  address := rec.address,
                                  derivationPath := rec.derivationPath,
                                  unlockedAtMs := ← IO.monoMsNow,
                                  ttlMs := ttlMs
                                }
                                enrolled := enrolled.push (.str name)
                pure <| .ok <| .obj #[
                  ("masterUnlocked", .bool true),
                  ("enrolled", .arr enrolled),
                  ("skipped", .arr skipped),
                  ("ttlMs", .num (Int.ofNat ttlMs))
                ]
  | "wallet.lock" =>
      -- Why: one-shot clear of every credential held in memory. Tears down
      -- per-slot unlocks AND the master KEK in a single state-modify so
      -- there is no instant where the master is gone but slot seeds linger.
      LeanCli.Daemon.State.lockAll state
      pure <| .ok <| .obj #[("locked", .bool true)]
  | "wallet.master.bindTpm" =>
      -- Why: post-init TPM binding. Wraps the existing wallet KEK under
      -- the TPM-sealed master key so future unlocks can come through the
      -- TPM PIN path. Two ways to obtain the KEK:
      --   (a) the daemon already has it loaded (caller previously ran
      --       `wallet.unlock`) — preferred, no passphrase prompt.
      --   (b) the caller supplies `passphrase` and we re-derive it from
      --       the manifest's `passphraseWrap`.
      -- TPM master key is bootstrapped if absent. PIN events flow through
      -- the standard `notify` channel (`pin-required`, `pin-success`,
      -- `pin-auth-failed`, `pin-locked-out`).
      if !(← LeanCli.Keystore.MasterPassphrase.existsOnDisk) then
        pure <| .error { code := -32032, message := "wallet master not initialized", data := none }
      else
        match ← LeanCli.Keystore.MasterPassphrase.loadManifest with
        | .error err =>
            pure <| .error { code := -32033, message := "master manifest is corrupt", data := some (.str err) }
        | .ok manifest =>
            match paramString req.params "masterPin" with
            | .error err => pure (.error err)
            | .ok pin =>
                -- Resolve the KEK: in-memory first, else derive from passphrase.
                let kekRes ← do
                  match ← LeanCli.Daemon.State.getMasterKek? state with
                  | some slot => pure (.ok slot.kek)
                  | none =>
                      match getField "passphrase" req.params >>= asString with
                      | none =>
                          pure (.error "wallet locked — provide `passphrase` or run `wallet.unlock` first")
                      | some p =>
                          LeanCli.Keystore.MasterPassphrase.unlockWithPassphrase manifest p
                match kekRes with
                | .error err =>
                    pure <| .error { code := -32034, message := "wallet KEK unavailable", data := some (.str err) }
                | .ok kek =>
                    -- Get the TPM master key (bootstrap if missing).
                    let tpmRes ←
                      if ← LeanCli.Keystore.MasterKey.existsOnDisk then
                        LeanCli.Keystore.MasterKey.unsealMaster pin notify
                      else
                        match ← LeanCli.Keystore.MasterKey.bootstrap pin notify with
                        | .error e => pure (.error e)
                        | .ok _ => LeanCli.Keystore.MasterKey.unsealMaster pin notify
                    match tpmRes with
                    | .error err =>
                        pure <| .error { code := -32020, message := "TPM master key unavailable", data := some (.str err) }
                    | .ok tpmKey =>
                        match ← LeanCli.Keystore.MasterPassphrase.addTpmWrap manifest kek tpmKey with
                        | .error err =>
                            pure <| .error { code := -32031, message := "failed to bind TPM wrap", data := some (.str err) }
                        | .ok updated =>
                            LeanCli.Keystore.MasterPassphrase.saveManifest updated
                            pure <| .ok <| .obj #[
                              ("withTpm", .bool true),
                              ("tpmAvailable", .bool true)
                            ]
  | "wallet.master.setTimeout" =>
      -- Why: update the persisted auto-lock TTL without re-typing the
      -- master passphrase. Rewrites `master.json` in place; the next
      -- `wallet.unlock` will pick up the new TTL. `timeoutMins == 0`
      -- disables auto-lock (slot lives until explicit `wallet.lock`).
      match getField "timeoutMins" req.params >>= asNat with
      | none =>
          pure <| .error { code := -32602, message := "timeoutMins required", data := none }
      | some mins =>
          if !(← LeanCli.Keystore.MasterPassphrase.existsOnDisk) then
            pure <| .error { code := -32032, message := "wallet master not initialized", data := none }
          else
            match ← LeanCli.Keystore.MasterPassphrase.loadManifest with
            | .error err =>
                pure <| .error { code := -32033, message := "master manifest is corrupt", data := some (.str err) }
            | .ok m =>
                let newTtl : Nat := if mins == 0 then 0 else mins * 60000
                let updated := { m with ttlMs := newTtl }
                LeanCli.Keystore.MasterPassphrase.saveManifest updated
                pure <| .ok <| .obj #[("ttlMs", .num (Int.ofNat newTtl))]
  | "wallet.lean_verified_addresses" =>
      -- Phase 1d: trusted-registry RPC. Returns the BIP-44-derived
      -- addresses for currently-unlocked seeds (plus SPHINCS-hybrid smart
      -- accounts). Read-only; no chain I/O. See
      -- `docs/PHASE1D_THREAT_MODEL.md` for the full threat model.
      --
      -- Params (all optional):
      --   paths      : Array String — defaults to ["m/44'/60'/0'/0", "m/44'/60'/0'/1"]
      --                Anything outside that allowlist is rejected
      --                with `bad_path` (no arbitrary BIP-32 walks).
      --   count      : Nat — per-path enumeration window; clamped to
      --                `cfg.trustedRegistryMaxPerPath` (default 5).
      --                Clamped silently, not errored — see threat 2.
      --
      -- Failure modes documented in the threat model:
      --   `locked`     — no seeds unlocked
      --   `bad_path`   — caller asked for a non-allowlisted prefix
      --
      -- The handler must NOT touch any signing primitive, must NOT
      -- call out to a node, and must NOT export private keys.
      let allowedPrefixes : List String :=
        ["m/44'/60'/0'/0", "m/44'/60'/0'/1"]
      let defaultPaths : Array String :=
        #["m/44'/60'/0'/0", "m/44'/60'/0'/1"]
      let paths : Array String :=
        match getField "paths" req.params with
        | some (.arr arr) => arr.filterMap (fun j => asString j)
        | _ => defaultPaths
      let requestedCount := paramNatD req.params "count" 5
      let count := min requestedCount cfg.trustedRegistryMaxPerPath
      -- Path-allowlist gate (threat 4).
      let badPath? : Option String :=
        paths.toList.find? (fun p => !(allowedPrefixes.contains p))
      match badPath? with
      | some bp =>
          pure <| .ok <| .obj #[
            ("ok", .bool false),
            ("error", .obj #[
              ("kind", .str "bad_path"),
              ("msg",  .str s!"path '{bp}' is not in the allowlist")
            ])
          ]
      | none =>
      let unlockedSlots ← LeanCli.Daemon.State.unlockedNames state
      -- Locked-seed gate (threat 3). The threat-model contract is
      -- explicit: when no BIP-44 seed is unlocked we return `locked`.
      -- Reasons:
      --   • The prompt's "Trusted Registry" header tells the LLM the
      --     list is "from your seed".
      --   • The user has not authorized address disclosure for this
      --     session; the unlock event is what gates that.
      if unlockedSlots.isEmpty then
        pure <| .ok <| .obj #[
          ("ok", .bool false),
          ("error", .obj #[
            ("kind", .str "locked"),
            ("msg",  .str "no seeds unlocked; run wallet.unlock or eoa.unlock first")
          ])
        ]
      else
      -- Resolve actual slot records (skip silently if expired between
      -- the name fetch and the slot fetch — TTL races are not errors).
      let mut entries : Array Json := #[]
      let mut storedAddrs : Array String := #[]
      let mut fingerprints : Array String := #[]
      -- 1. Stored-accounts walk. Once *some* seed is unlocked the user
      --    has authorized address disclosure for this session, so every
      --    on-disk EoaStore slot's already-realized sub-accounts (the
      --    `Record.accounts` array) become visible — these are the
      --    wallets the user creates and references by name from the CLI
      --    / TUI (e.g. "leanWallet/fresh1"). Locked slots are included
      --    with `unlocked:false` so the agent knows it can't sign with
      --    them yet; addresses themselves are public, the secret is the
      --    seed. Labelled accounts win deduplication against the BIP-44
      --    enumeration below.
      let allEoaNames ← LeanCli.Wallet.EoaStore.list
      for name in allEoaNames do
        match ← LeanCli.Wallet.EoaStore.load name with
        | .error _ => pure ()
        | .ok rec =>
            let isUnlocked := (← LeanCli.Daemon.State.getUnlocked? state name).isSome
            for acct in rec.accounts do
              let baseFields : Array (String × Json) := #[
                ("kind",     .str "eoa"),
                ("slot",     .str name),
                ("path",     .str acct.path),
                ("address",  .str acct.address),
                ("unlocked", .bool isUnlocked)
              ]
              let fields : Array (String × Json) :=
                match acct.label with
                | some l => baseFields.push ("label", .str l)
                | none   => baseFields
              entries := entries.push (.obj fields)
              storedAddrs := storedAddrs.push acct.address.toLower
      -- 2. Per-seed BIP-44 enumeration (unlocked slots only). Skips any
      --    address already surfaced by the stored-accounts walk so a
      --    labelled sub-account always wins over its bare derived twin.
      for name in unlockedSlots do
        match ← LeanCli.Daemon.State.getUnlocked? state name with
        | none => pure ()
        | some slot =>
            -- Per-slot fingerprint (best-effort; failure is non-fatal).
            match ← seedFingerprintFromSeed slot.seed with
            | .ok fp => fingerprints := fingerprints.push fp
            | .error _ => pure ()
            -- For each allowlisted prefix the user asked about,
            -- enumerate `count` indices.
            for pathPrefix in paths do
              for i in [0:count] do
                let path := s!"{pathPrefix}/{i}"
                match ← deriveAddressFromSeed slot.seed path with
                | .error _ => pure ()  -- skip — malformed path or deriver hiccup
                | .ok address =>
                    if storedAddrs.contains address.toLower then
                      pure ()  -- already surfaced (with label) by the stored walk
                    else
                      entries := entries.push <| .obj #[
                        ("kind",     .str "eoa"),
                        ("slot",     .str name),
                        ("path",     .str path),
                        ("address",  .str address),
                        ("unlocked", .bool true)
                      ]
      -- 3. SPHINCS-hybrid 4337 smart-account records (`kind:"sphincs"`).
      --    The user controls these via a hybrid ECDSA+SPHINCS+ owner; the
      --    smart-account address is the CREATE2-derived contract that
      --    holds the funds. Records without a computed
      --    `smartAccountAddress` are skipped (factory not yet wired up
      --    for that paramSet/chain). Enumeration failure is non-fatal —
      --    we still want EOA entries to land.
      try
        let sphincsNames ← LeanCli.Wallet.SphincsHybridStore.listSlotNames
        for sname in sphincsNames do
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord sname with
          | .error _ => pure ()
          | .ok rec =>
              match rec.smartAccountAddress with
              | none => pure ()
              | some sa =>
                  entries := entries.push <| .obj #[
                    ("kind",                .str "sphincs"),
                    ("slot",                .str sname),
                    ("paramSet",            .str rec.paramSet.toString),
                    ("chainId",             .num (Int.ofNat rec.chainId)),
                    ("ownerAddress",        .str rec.ownerAddress),
                    ("smartAccountAddress", .str sa),
                    ("address",             .str sa)
                  ]
      catch _ => pure ()
      -- Combine fingerprints into a single stable string. If multiple
      -- seeds are unlocked simultaneously the registry shows all of
      -- their fingerprints joined by ","; rotation of any one will
      -- change the joined string.
      let combinedFp : String :=
        if fingerprints.isEmpty then ""
        else String.intercalate "," fingerprints.toList
      pure <| .ok <| .obj #[
        ("ok",              .bool true),
        ("addresses",       .arr entries),
        ("count",           .num (Int.ofNat entries.size)),
        ("seedFingerprint", .str combinedFp)
      ]
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.WalletRpc
