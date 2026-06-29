import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.Server.Journal
import LeanCli.Daemon.Server.AddrGuard
import LeanCli.Crypto.Hex
import LeanCli.Daemon.State
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Tx
import LeanCli.Keystore.MasterPassphrase
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Sphincs.Bridge
import LeanCli.Sphincs.Send
import LeanCli.Sphincs.UserOp
import LeanCli.Util.Units
import LeanCli.Wallet.EOA
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.SphincsHybridStore
import LeanCli.Wallet.ExecuteBatch

/-!
# Daemon server: `sphincs.*` RPC family

Post-quantum hybrid ERC-4337 (SPHINCS+ + ECDSA) account flow.
Covering the full lifecycle of a hybrid smart-account:

  sphincs.account.create / list / show / computeAddress / deploy /
  sphincs.account.send / sendBatch / encodeBatch / rotateOwner /
                          encodeRotateOwner / commitRotation / resyncOwner /
                          deployStatus / getUserOp
  sphincs.bundler.show / sphincs.bundler.check
  sphincs.factory.deploy

The userOp signing flow is `executeSphincsUserOp` (private to this
module): builds the EntryPoint userOp, signs it with the SPHINCS+
shim, and submits via the configured bundler. Trust posture: standard
decode → simulate → ConfirmGate before signing.
-/

namespace LeanCli.Daemon.Server.SphincsRpc

open LeanCli.Encoding.Json
open LeanCli.Keystore.Tpm2Runtime
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

private def chainNameGuess (cid : Nat) : String :=
  if cid = 11155111 then "sepolia"
  else if cid = 1 then "mainnet"
  else ""

/-- Conservative base-fee fallback for ERC-4337 UserOps when
    `eth_gasPrice` times out. A zero gas-price read used to produce a
    `maxFeePerGas` below Candide's current base-fee floor after the
    multi-second SPHINCS signing step. The cap is not the effective fee;
    it only needs to be high enough for bundler admission. -/
private def minUserOpFeeBaseWei : Nat := 5_000_000_000

/-- SPHINCS `executeBatch` flows can contain protocol calls whose nested
    execution is badly under-estimated by the bundler when the estimate uses
    dummy signatures. Keep single sends lean, but never let a batch go out
    with the 200k single-call fallback that starves Aave supply minting. -/
private def minExecuteBatchCallGas : Nat := 1_100_000

private def isExecuteBatchCallData (callData : ByteArray) : Bool :=
  if callData.size ≥ 4 then
    callData[0]! == 0x34 && callData[1]! == 0xfc &&
    callData[2]! == 0xd5 && callData[3]! == 0xbe
  else
    false

/-- Best-effort: query the configured factory's `getAddress(...)` view and
    return the resulting smart-account address. Swallows every error so
    callers can use this opportunistically (e.g. auto-populating
    `smartAccountAddress` on a freshly created slot without making the
    create RPC fail when the factory isn't deployed yet). -/
private def tryComputeSmartAccountAddress (cfg : Config)
    (rec : LeanCli.Wallet.SphincsHybridStore.Record) : IO (Option String) := do
  let chainName := chainNameGuess rec.chainId
  match sphincsFactoryFor cfg chainName rec.paramSet,
        endpointForChain cfg (some chainName) with
  | .error _, _ | _, .error _ => pure none
  | .ok factory, .ok ep =>
      match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
          (LeanCli.Crypto.Hex.encode "getAddress(address,bytes32,bytes32)".toByteArray) with
      | .error _ => pure none
      | .ok kh =>
          -- Build the calldata in ByteArray space and hex-encode once at
          -- the end. `Hex.encode` always prepends "0x", so the previous
          -- `"0x" ++ Hex.encode a ++ Hex.encode b ++ ...` pattern emitted
          -- strings with embedded "0x" substrings — Sepolia geth/erigon
          -- rejects them as "invalid hex string into hexutil.Bytes".
          let selBytes := kh.extract 0 4
          let ownerB := (LeanCli.Sphincs.UserOp.hexToWord32? rec.ownerAddress).getD ByteArray.empty
          let pkSeedB := (LeanCli.Sphincs.UserOp.hexToWord32? rec.pkSeed).getD ByteArray.empty
          let pkRootB := (LeanCli.Sphincs.UserOp.hexToWord32? rec.pkRoot).getD ByteArray.empty
          let dataHex := LeanCli.Crypto.Hex.encode
            (selBytes ++ ownerB ++ pkSeedB ++ pkRootB)
          match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep factory dataHex "latest" none with
          | .error _ => pure none
          | .ok ret =>
              let s := (asString ret).getD ""
              let cleaned := if s.startsWith "0x" then (s.drop 2).toString else s
              if cleaned.length < 64 then pure none
              else pure (some ("0x" ++ String.ofList (cleaned.toList.drop (cleaned.length - 40))))

/-- Full SPHINCS- hybrid UserOperation pipeline: unlock the SPHINCS- sk,
    derive the ECDSA private key from the wallet attachment, fetch nonce
    + gas + domain separator, build initCode if the account isn't yet
    deployed, run bundler gas estimation, dual-sign the userOpHash, and
    submit via the configured bundler.

    `callData` is the `userOp.callData` field — the caller decides what
    target/value/data shape it carries (e.g. `execute(...)` from
    `sphincs.account.send` or a self-call from a future
    `rotateOwner`/`rotateKeys` RPC).

    `params` carries optional `passphrase` + `chain` overrides; only
    those two fields are consulted.

    `journalMethod` labels the local journal entry (`"sphincs.userOp"`
    for single `execute(...)` sends, `"sphincs.userOp.batch"` for
    `executeBatch(...)` sends). -/
-- `innerTo` / `innerValue` / `innerData` describe what the userOp
-- dispatches to, ONLY for the journal entry — the user-meaningful
-- to/value/data instead of the ABI-encoded envelope. For a single send
-- they are the inner target; for a batch they describe the self-call
-- `executeBatch(...)` (to = the account, data = the batch envelope).
-- The actual `userOp.callData` is the explicit `callData` argument.
private partial def executeSphincsUserOp
    (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (rec : LeanCli.Wallet.SphincsHybridStore.Record)
    (callData : ByteArray)
    (innerTo : String) (innerValue : Nat) (innerData : ByteArray)
    (params : Json)
    (journalMethod : String := "sphincs.userOp") :
    IO (Except RpcError Json) := do
  match rec.smartAccountAddress with
  | none =>
      pure <| .error
        { code := -32033,
          message := "smartAccountAddress unset — run sphincs.account.computeAddress (or .deploy) first",
          data := none }
  | some sender =>
      let chainName := paramStringD params "chain" (chainNameGuess rec.chainId)
      -- Optional `backend` param ("cpu" | "vulkan" | "gpu") selects the
      -- signer implementation. Meaningful only for SLH-DSA-SHA2-128-24
      -- (the Vulkan GPU signer); ignored by `resolveExecutable` for C13 /
      -- JARDIN. Unparseable / absent → CPU. `signWithVerify` re-verifies
      -- the result on the CPU reference regardless, so a faulty GPU
      -- signature is never broadcast.
      let signerBackend : LeanCli.Sphincs.SignerBackend :=
        ((paramString params "backend").toOption.bind
          LeanCli.Sphincs.SignerBackend.parse?).getD .cpu
      match sphincsBundlerFor cfg chainName,
            endpointForChain cfg (some chainName) with
      | .error e, _ | _, .error e =>
          pure <| .error
            { code := -32030, message := "sphincs bundler/endpoint unavailable",
              data := some (.str e) }
      | .ok bundlerUrl, .ok ep =>
          -- 1) Unlock SPHINCS- sk (master KEK first, slot passphrase fallback).
          let skResult : IO (Except String String) := do
            match ← LeanCli.Daemon.State.getMasterKek? state with
            | some mslot =>
                match ← LeanCli.Wallet.SphincsHybridStore.openWithMaster mslot.kek rec with
                | .ok sk => pure (.ok sk)
                | .error _ =>
                    match paramString params "passphrase" with
                    | .error _ => pure (.error "passphrase required (master path failed)")
                    | .ok pp => LeanCli.Wallet.SphincsHybridStore.openSk rec pp
            | none =>
                match paramString params "passphrase" with
                | .error _ => pure (.error "passphrase required (master KEK not loaded)")
                | .ok pp => LeanCli.Wallet.SphincsHybridStore.openSk rec pp
          match ← skResult with
          | .error e => pure <| .error { code := -32011, message := "sphincs sk unlock failed", data := some (.str e) }
          | .ok sphincsSkHex =>
              -- 2) Resolve ECDSA half via the wallet attachment.
              let attach := rec.ecdsaAttachment
              let walletName := match attach with
                | .existing wn _ => wn | .derived wn _ => wn
              match ← LeanCli.Wallet.EoaStore.load walletName with
              | .error e => pure <| .error { code := -32010, message := "wallet not found", data := some (.str e) }
              | .ok wRec =>
                  let pathExc : Except String String := match attach with
                    | .existing _ idx =>
                        match wRec.accounts.find? (fun a => a.index == idx) with
                        | some a => .ok a.path
                        | none => .error s!"wallet has no account #{idx}"
                    | .derived _ dp => .ok dp.asString
                  match pathExc with
                  | .error e => pure <| .error { code := -32012, message := "ecdsa path resolve failed", data := some (.str e) }
                  | .ok path =>
                      match ← unlockedSlot state walletName with
                      | .error e => pure (.error e)
                      | .ok wSlot =>
                          match ← derivePrivateKeyFromSeed wSlot.seed path with
                          | .error e => pure <| .error { code := -32012, message := "ecdsa key derive failed", data := some (.str e) }
                          | .ok privKey =>
                              -- 3) Nonce, gas, initCode. The nonce calldata is
                              -- entryPoint.getNonce(sender, key=0): selector ‖
                              -- pad32(sender) ‖ pad32(0). Build in ByteArray
                              -- and hex-encode once (Hex.encode always
                              -- prepends "0x", so a "++" of two
                              -- already-encoded strings would yield an
                              -- embedded-"0x" hex blob that the RPC rejects).
                              let nonceSelBytes :=
                                (LeanCli.Crypto.Hex.decode
                                  Sphincs.Send.entryPointGetNonceSelector).getD ByteArray.empty
                              let nonceCalldata :=
                                LeanCli.Crypto.Hex.encode
                                  (nonceSelBytes
                                    ++ (LeanCli.Sphincs.UserOp.hexToWord32? sender).getD ByteArray.empty
                                    ++ LeanCli.Sphincs.UserOp.padLeft32 ByteArray.empty)
                              let nonceN : Nat ← do
                                match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep
                                    Sphincs.Send.entryPointV09Address nonceCalldata "latest" none with
                                | .ok r => pure ((parseHexQuantity ((asString r).getD "0x0")).getD 0)
                                | .error _ => pure 0
                              let gp ← LeanCli.RPC.Outbound.gasPrice cfg.policy ep none
                              let pp ← LeanCli.RPC.Outbound.maxPriorityFeePerGas cfg.policy ep none
                              let parseHexJ (j : Except String Json) : Nat :=
                                match j with
                                | .ok jj => (parseHexQuantity ((asString jj).getD "0x0")).getD 0
                                | .error _ => 0
                              let gasPriceN := parseHexJ gp
                              let feeBase := Nat.max gasPriceN minUserOpFeeBaseWei
                              let priorityFee := Nat.max (parseHexJ pp) minPriorityFeeWei
                              -- Bundlers (Candide, Pimlico, …) reject userOps
                              -- whose `maxFeePerGas` < their estimate of the
                              -- next block's base fee. `eth_gasPrice` can
                              -- also fail transiently; parsing that as zero
                              -- must not leak into a signed UserOp. Use a
                              -- small floor and pad to `3*base +
                              -- priorityFee` so the cap survives the
                              -- multi-second SPHINCS signature window.
                              let maxFee := 3 * feeBase + priorityFee
                              let initCodeBytes ← do
                                match ← LeanCli.RPC.Outbound.call cfg.policy ep
                                    .getCode (.arr #[.str sender, .str "latest"]) none with
                                | .ok r =>
                                    let codeHex := (asString r).getD "0x"
                                    if Sphincs.Send.hasCodeAt codeHex then pure ByteArray.empty
                                    else
                                      match sphincsFactoryFor cfg chainName rec.paramSet with
                                      | .error _ => pure ByteArray.empty
                                      | .ok factory =>
                                          match ← Sphincs.Send.buildInitCode factory
                                              rec.ownerAddress rec.pkSeed rec.pkRoot with
                                          | .error _ => pure ByteArray.empty
                                          | .ok bs => pure bs
                                | .error _ => pure ByteArray.empty
                              -- 4) Skeleton + estimate gas.
                              let senderAddrBs : ByteArray :=
                                (LeanCli.Crypto.Hex.decode sender).getD ByteArray.empty
                              let callGasFloor :=
                                if isExecuteBatchCallData callData then minExecuteBatchCallGas else 200000
                              -- Initial heuristic gas params for the
                              -- estimate-request skeleton. Must fit under
                              -- the bundler's total-gas cap (Candide:
                              -- 15M for the whole userOp), otherwise the
                              -- estimate request ITSELF is rejected and
                              -- the fallback would carry the same
                              -- too-large values into the send request.
                              --
                              -- Real on-chain cost for SPHINCS- C13
                              -- _validateSignature (verifier staticcall +
                              -- ECDSA recover + abi.decode of the dual
                              -- signature): full hybrid handleOps ≈ 293 K
                              -- (C13 verify ≈ 188 K). We pad to 800 K to
                              -- cover the first-send-also-deploy case
                              -- where the EntryPoint also has to CREATE2
                              -- the SphincsAccount contract before
                              -- calling _validateSignature.
                              --
                              -- NOTE: this skeleton value only shapes the
                              -- ESTIMATE request — the real send uses the
                              -- bundler's returned vgl PLUS
                              -- `paramSet.verifyGasFloor` (below). The
                              -- estimate runs with a dummy ECDSA sig, which
                              -- short-circuits `_validateSignature` before
                              -- the ~188 K verifier staticcall, so the
                              -- estimate alone under-reports vgl and the
                              -- real send trips AA26 unless we add the
                              -- verifier cost back.
                              -- preVerificationGas covers the EntryPoint's
                              -- per-byte calldata cost. A SPHINCS-C13 signature
                              -- alone is ~3688 bytes, and the abi.encode of
                              -- (bytes ecdsaSig, bytes sphincsSig) pushes the
                              -- full userOp calldata to ~9 KB. Candide's
                              -- bundler computes a per-userOp minimum from
                              -- that and rejects estimate requests that
                              -- under-shoot (typical observed minimum on
                              -- C13 sends: ~0x15f00 ≈ 90 K). 200 K gives
                              -- comfortable margin without re-tripping the
                              -- 15 M total-gas cap.
                              let opSkeleton : LeanCli.Sphincs.UserOp.PackedUserOperation := {
                                sender             := senderAddrBs,
                                nonce              := LeanCli.Sphincs.UserOp.padLeft32
                                  ((LeanCli.Crypto.Hex.decode (Sphincs.Send.natToEvenHex nonceN)).getD ByteArray.empty),
                                initCode           := initCodeBytes,
                                callData           := callData,
                                accountGasLimits   := Sphincs.Send.packTwoHalves 800000 callGasFloor,
                                preVerificationGas := Sphincs.Send.natToWord32 200000,
                                gasFees            := Sphincs.Send.packTwoHalves priorityFee maxFee,
                                paymasterAndData   := ByteArray.empty
                              }
                              let dummyEcdsa := ByteArray.mk (Array.replicate 65 (0 : UInt8))
                              let dummySphincs := ByteArray.mk
                                (Array.replicate rec.paramSet.expectedSigBytes (0 : UInt8))
                              let dummySig := Sphincs.Send.abiEncodeBytesPair dummyEcdsa dummySphincs
                              let dummyOpJson := Sphincs.Send.packedUserOpToJson opSkeleton dummySig
                              let estParams : Json :=
                                .arr #[dummyOpJson, .str Sphincs.Send.entryPointV09Address]
                              let (vgl, cgl, pvg) ← do
                                match ← Sphincs.Send.bundlerCall bundlerUrl
                                    "eth_estimateUserOperationGas" estParams with
                                | .ok est =>
                                    let getNat (k : String) : Nat :=
                                      match getField k est >>= asString with
                                      | some s => (parseHexQuantity s).getD 0
                                      | none => 0
                                    let vgl0 := getNat "verificationGasLimit"
                                    let cgl0 := getNat "callGasLimit"
                                    let pvg0 := getNat "preVerificationGas"
                                    -- The estimate's ECDSA short-circuit
                                    -- hides the SPHINCS verifier staticcall;
                                    -- add it back so the real send doesn't
                                    -- trip AA26 over verificationGasLimit.
                                    pure
                                      ((if vgl0 = 0 then 800000 else vgl0)
                                          + rec.paramSet.verifyGasFloor,
                                       Nat.max (if cgl0 = 0 then 200000 else cgl0) callGasFloor,
                                       if pvg0 = 0 then 200000 else pvg0)
                                | .error _ =>
                                    pure (800000 + rec.paramSet.verifyGasFloor,
                                          callGasFloor, 200000)
                              let userOp : LeanCli.Sphincs.UserOp.PackedUserOperation :=
                                { opSkeleton with
                                    accountGasLimits   := Sphincs.Send.packTwoHalves vgl cgl,
                                    preVerificationGas := Sphincs.Send.natToWord32 pvg }
                              -- 5) Domain separator + userOpHash. We compute the
                              -- EIP-712 domain separator locally instead of
                              -- eth_call'ing `getDomainSeparatorV4()` — that
                              -- method isn't public on EntryPoint v0.9 (OZ
                              -- EIP712 only exposes `_domainSeparatorV4()`
                              -- internally), so the call reverts. The local
                              -- compute matches EntryPoint v0.9's
                              -- `EIP712("ERC4337", "1")` constructor.
                              match ← Sphincs.Send.computeDomainSeparator rec.chainId with
                              | .error e => pure <| .error { code := -32020, message := "domain separator computation failed", data := some (.str e) }
                              | .ok ds =>
                                  if ds.size ≠ 32 then
                                    pure <| .error { code := -32034, message := s!"unexpected domain separator size {ds.size}", data := none }
                                  else
                                    match ← LeanCli.Sphincs.UserOp.userOpHash userOp ds with
                                    | .error e => pure <| .error { code := -32031, message := "userOpHash failed", data := some (.str e) }
                                    | .ok userOpH =>
                                        match ← LeanCli.Wallet.EOA.signDigestIO privKey userOpH with
                                        | .error e => pure <| .error { code := -32013, message := "ecdsa sign failed", data := some (.str e) }
                                        | .ok ecdsaSig =>
                                            let rBs := Sphincs.Send.natToWord32 ecdsaSig.r
                                            let sBs := Sphincs.Send.natToWord32 ecdsaSig.s
                                            -- libsecp256k1 returns v as the
                                            -- recovery id {0, 1}, but the
                                            -- Ethereum / OZ ECDSA.recover
                                            -- convention is {27, 28}. The
                                            -- upstream `SphincsAccount.sol`
                                            -- uses OZ's recover which throws
                                            -- `ECDSAInvalidSignature` for
                                            -- v < 27 (ecrecover returns 0).
                                            -- Normalize here.
                                            let vByte : UInt8 :=
                                              if ecdsaSig.v < 27 then ecdsaSig.v + 27
                                              else ecdsaSig.v
                                            let vBs := ByteArray.empty.push vByte
                                            let ecdsaBytes := rBs ++ sBs ++ vBs
                                            let userOpHashHex := LeanCli.Crypto.Hex.encode userOpH
                                            -- The SPHINCS+ shim call is the
                                            -- expensive ("the grind") step:
                                            -- C13 takes seconds even on a fast
                                            -- machine. Bracket it with start /
                                            -- done notifications so the TUI's
                                            -- RpcRunner can show live status,
                                            -- and capture the elapsed time so
                                            -- the post-broadcast journal entry
                                            -- can record it for later review.
                                            let paramSetStr := rec.paramSet.toString
                                            let backendStr := signerBackend.toString
                                            notify "sphincs:sign-start" (.obj #[
                                              ("paramSet", .str paramSetStr),
                                              ("backend", .str backendStr),
                                              ("sender", .str sender),
                                              ("digest", .str userOpHashHex)
                                            ])
                                            let signStartMs ← IO.monoMsNow
                                            let signResult ← LeanCli.Sphincs.signWithVerify rec.paramSet
                                                sphincsSkHex rec.pkSeed rec.pkRoot userOpHashHex
                                                (backend := signerBackend)
                                            let signEndMs ← IO.monoMsNow
                                            let signMs := signEndMs - signStartMs
                                            match signResult with
                                            | .error e =>
                                                notify "sphincs:sign-done" (.obj #[
                                                  ("paramSet", .str paramSetStr),
                                                  ("backend", .str backendStr),
                                                  ("elapsedMs", .num (Int.ofNat signMs)),
                                                  ("ok", .bool false),
                                                  ("error", .str (reprStr e))
                                                ])
                                                pure <| .error { code := -32014, message := "sphincs sign failed", data := some (.str (reprStr e)) }
                                            | .ok sphincsSigHex =>
                                                notify "sphincs:sign-done" (.obj #[
                                                  ("paramSet", .str paramSetStr),
                                                  ("backend", .str backendStr),
                                                  ("elapsedMs", .num (Int.ofNat signMs)),
                                                  ("ok", .bool true),
                                                  ("sigChars", .num (Int.ofNat sphincsSigHex.length))
                                                ])
                                                let sphincsBytes := (LeanCli.Crypto.Hex.decode sphincsSigHex).getD ByteArray.empty
                                                let signature := Sphincs.Send.abiEncodeBytesPair ecdsaBytes sphincsBytes
                                                let opJson := Sphincs.Send.packedUserOpToJson userOp signature
                                                let subParams : Json :=
                                                  .arr #[opJson, .str Sphincs.Send.entryPointV09Address]
                                                notify "sphincs:bundler-submit" (.obj #[
                                                  ("bundler", .str bundlerUrl),
                                                  ("sender", .str sender)
                                                ])
                                                match ← Sphincs.Send.bundlerCall bundlerUrl "eth_sendUserOperation" subParams with
                                                | .error e => pure <| .error { code := -32021, message := "bundler error", data := some (.str e) }
                                                | .ok r =>
                                                    let userOpHash := (asString r).getD ""
                                                    -- Append to the slot's local NDJSON journal.
                                                    -- innerTo/innerValue/innerData carry what the user
                                                    -- actually intended (not the ABI-encoded UserOp
                                                    -- envelope) so the HistoryPanel shows "to 0xRouter"
                                                    -- rather than "to 0xSmartAccount". The userOp's
                                                    -- identity is the bundler's userOpHash; we mirror
                                                    -- it into `txHash` (the canonical journal column)
                                                    -- AND `userOpHash` so existing readers don't have
                                                    -- to change shape, and a future inclusion-tx
                                                    -- lookup can rewrite `txHash` in a status update.
                                                    -- `Hex.encode` already prepends `0x`; don't double it.
                                                    let innerDataHex := LeanCli.Crypto.Hex.encode innerData
                                                    journalRecord rec.name sender innerTo userOpHash innerDataHex
                                                      journalMethod innerValue 0 rec.chainId none
                                                      none none none
                                                      (signMs? := some signMs)
                                                      (paramSet? := some paramSetStr)
                                                      (userOpHash? := some userOpHash)
                                                    pure <| .ok <| .obj #[
                                                      ("userOpHash", .str userOpHash),
                                                      ("sender", .str sender),
                                                      ("bundler", .str bundlerUrl),
                                                      ("signMs", .num (Int.ofNat signMs)),
                                                      ("paramSet", .str paramSetStr),
                                                      ("backend", .str backendStr)
                                                    ]


/-- Parse a `legs` array param (`[{to, value|valueEth, data}, …]`) into a
    list of `ExecuteBatch.Call`. `data` stays a 0x-hex string (the encoder
    strips the prefix); `value` prefers human `valueEth`, falling back to
    wei `value`. Returns `none` if `legs` is absent/empty or any leg lacks
    a string `to`. Shared by `sphincs.account.encodeBatch` (sim/preview)
    and `sphincs.account.sendBatch` (broadcast) so both agree byte-for-byte
    on the encoded batch. -/
private def parseBatchLegs (params : Json) :
    Option (List LeanCli.Wallet.ExecuteBatch.Call) := do
  let legsJson ← getField "legs" params >>= asArray
  if legsJson.isEmpty then none
  else
    let parseLeg (j : Json) : Option LeanCli.Wallet.ExecuteBatch.Call := do
      let to ← getField "to" j >>= asString
      let value : Nat :=
        match getField "valueEth" j >>= asString with
        | some ethStr => (LeanCli.Util.Units.parseUnits ethStr 18).getD 0
        | none =>
            match getField "value" j >>= asString with
            | some vs => (vs.toNat?).getD ((parseHexQuantity vs).getD 0)
            | none => (getField "value" j >>= asNat).getD 0
      let data := (getField "data" j >>= asString).getD "0x"
      some { target := to, value := value, data := data }
    legsJson.toList.mapM parseLeg

/-- Handle every `sphincs.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "sphincs.account.create" =>
      -- Create a hybrid ECDSA + SPHINCS- ERC-4337 account record. The
      -- SPHINCS sk is generated locally by the shim from a fresh
      -- 48-/32-byte random seed (per `ParamSet.expectedSeedBytes`),
      -- sealed under the per-slot passphrase, and additionally wrapped
      -- under the daemon's master KEK if one is loaded. The ECDSA half
      -- references an existing wallet account or a freshly-derived
      -- sub-path under the wallet's BIP-39 seed.
      --
      -- Params:
      --   name           : slot name (unique in sphincs-hybrid namespace)
      --   paramSet       : "SLH-DSA-SHA2-128-24" | "C13"
      --   chainId        : optional (defaults to daemon's primary chainId)
      --   walletName     : EOA wallet supplying the ECDSA half
      --   ecdsaKind      : "existing" | "derived"   (default "existing")
      --   accountIndex   : (existing only) index in wallet's accounts; default 0
      --   path           : (derived only) BIP-44 path; default = wallet's path
      --   walletPassphrase : passphrase to unlock the wallet for `derived` ECDSA
      --   passphrase     : per-slot passphrase used to seal the SPHINCS- sk
      match paramName req.params,
            paramString req.params "paramSet",
            paramString req.params "walletName" with
      | .ok name, .ok psStr, .ok walletName =>
          let chainId := paramNatD req.params "chainId" cfg.chainId
          let ecdsaKind := paramStringD req.params "ecdsaKind" "existing"
          -- Passphrase is optional when the master KEK is in memory
          -- (same pattern as `eoa.create` / `saveMnemonicSlot`). If
          -- empty/missing AND KEK is loaded, we mint a 32-byte ephemeral
          -- passphrase that only ever exists in this process; the slot
          -- becomes master-unlockable on next call thanks to the
          -- best-effort `masterWrap` write below. The ephemeral isn't
          -- returned to the client and isn't a recovery factor.
          let userSuppliedPassphrase : Bool :=
            match paramString req.params "passphrase" with
            | .ok p => p.length > 0
            | .error _ => false
          let masterSlot? ← LeanCli.Daemon.State.getMasterKek? state
          let passphraseExcept : Except String String := do
            match paramString req.params "passphrase" with
            | .ok p =>
                if p.length > 0 then .ok p
                else if masterSlot?.isSome then .ok ""  -- placeholder, replaced below
                else .error "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
            | .error _ =>
                if masterSlot?.isSome then .ok ""
                else .error "missing passphrase (no master KEK loaded — set one with `wallet master init` or pick a per-slot passphrase)"
          match passphraseExcept with
          | .error e =>
              pure <| .error { invalidParams with data := some (.str e) }
          | .ok rawPp =>
          let slotPassphrase ←
            if rawPp.length > 0 then pure rawPp
            else do
              let bytes ← LeanCli.Crypto.Random.getRandomBytes 32
              pure (LeanCli.Crypto.Hex.encode bytes)
          match LeanCli.Sphincs.ParamSet.parse? psStr with
          | none =>
              pure <| .error
                { invalidParams with data := some (.str s!"unknown paramSet: {psStr}") }
          | some ps =>
              match ← LeanCli.Wallet.EoaStore.load walletName with
              | .error err =>
                  pure <| .error
                    { code := -32010, message := "wallet not found",
                      data := some (.str err) }
              | .ok walletRec =>
                  -- Resolve ECDSA owner address + attachment record.
                  let resolved : IO
                      (Except String (String × LeanCli.Wallet.Account.EcdsaAttachment)) :=
                    match ecdsaKind with
                    | "existing" =>
                        let idx := paramNatD req.params "accountIndex" 0
                        match walletRec.accounts.find? (fun a => a.index == idx) with
                        | none =>
                            pure (.error s!"wallet '{walletName}' has no account at index {idx}")
                        | some acct =>
                            pure (.ok (acct.address,
                                        .existing walletName idx))
                    | "derived" =>
                        let pathStr :=
                          paramStringD req.params "path" walletRec.derivationPath
                        match paramString req.params "walletPassphrase" with
                        | .error _ =>
                            pure (.error "ecdsaKind='derived' requires walletPassphrase")
                        | .ok walletPp => do
                            match ← LeanCli.Wallet.EoaStore.unlockSeedIO
                                walletRec walletPp with
                            | .error err => pure (.error s!"wallet unlock: {err}")
                            | .ok seed => do
                                match ← deriveAddressFromSeed seed pathStr with
                                | .error err => pure (.error err)
                                | .ok addr =>
                                    match LeanCli.Wallet.SphincsHybridStore.derivationPathFromString
                                          pathStr with
                                    | .error err => pure (.error err)
                                    | .ok dpath =>
                                        pure (.ok (addr, .derived walletName dpath))
                    | other =>
                        pure (.error s!"unknown ecdsaKind '{other}' (use 'existing' or 'derived')")
                  match ← resolved with
                  | .error err =>
                      pure <| .error
                        { invalidParams with data := some (.str err) }
                  | .ok (ownerAddress, attachment) =>
                      -- Generate fresh SPHINCS- seed + spawn shim keygen.
                      -- Optional `backend` ("cpu" | "vulkan") selects the
                      -- signer; meaningful only for SLH-DSA-SHA2 (the
                      -- Vulkan GPU keygen is ~180× faster than the CPU
                      -- reference). Ignored for C13 / JARDIN.
                      let keygenBackend : LeanCli.Sphincs.SignerBackend :=
                        ((paramString req.params "backend").toOption.bind
                          LeanCli.Sphincs.SignerBackend.parse?).getD .cpu
                      let seedBytes ← LeanCli.Crypto.Random.getRandomBytes
                        ps.expectedSeedBytes
                      let seedHex := LeanCli.Crypto.Hex.encode seedBytes
                      match ← LeanCli.Sphincs.keygen ps seedHex keygenBackend with
                      | Except.error e =>
                          pure <| Except.error
                            { code := -32040,
                              message := "sphincs keygen failed",
                              data := some (.str (reprStr e)) }
                      | Except.ok km =>
                          let kdfSalt ← LeanCli.Crypto.Random.getRandomBytes 16
                          let iters := LeanCli.Wallet.SphincsHybridStore.defaultKdfIters
                          match ← LeanCli.Wallet.SphincsHybridStore.sealSk
                              name ps ownerAddress slotPassphrase km.sk
                              kdfSalt iters with
                          | .error err =>
                              pure <| .error
                                { code := -32041,
                                  message := "sphincs sk seal failed",
                                  data := some (.str err) }
                          | .ok passphraseCt =>
                              -- Best-effort master-KEK wrap. Failure here
                              -- is non-fatal — the slot still works
                              -- through `passphraseCiphertext`. Reuses
                              -- `masterSlot?` captured above so we don't
                              -- race with a TTL-driven re-lock.
                              let masterWrap? : Option ByteArray ←
                                match masterSlot? with
                                | none => pure none
                                | some mslot =>
                                    match ← LeanCli.Wallet.SphincsHybridStore.sealUnderMaster
                                        mslot.kek name ps ownerAddress km.sk with
                                    | .error _ => pure none
                                    | .ok w => pure (some w)
                              let now ← IO.monoMsNow
                              let baseRecord : LeanCli.Wallet.SphincsHybridStore.Record := {
                                version := LeanCli.Wallet.SphincsHybridStore.currentVersion,
                                name := name,
                                paramSet := ps,
                                chainId := chainId,
                                ecdsaAttachment := attachment,
                                ownerAddress := ownerAddress,
                                pkSeed := km.pkSeed,
                                pkRoot := km.pkRoot,
                                kdfSalt := kdfSalt,
                                kdfIters := iters,
                                passphraseCiphertext := passphraseCt,
                                masterWrap := masterWrap?,
                                smartAccountAddress := none,
                                customPassphrase := userSuppliedPassphrase,
                                createdAt := now / 1000
                              }
                              -- Auto-compute the counterfactual address when a
                              -- factory is configured for (chain, paramSet).
                              -- The helper swallows errors so the create RPC
                              -- still succeeds even if the factory is
                              -- unreachable or not yet deployed.
                              let saa? ← tryComputeSmartAccountAddress cfg baseRecord
                              let slotRecord := { baseRecord with smartAccountAddress := saa? }
                              try
                                LeanCli.Wallet.SphincsHybridStore.writeRecord slotRecord
                                pure <| .ok <| .obj #[
                                  ("name",         .str name),
                                  ("paramSet",     .str ps.toString),
                                  ("chainId",      .num (Int.ofNat chainId)),
                                  ("ownerAddress", .str ownerAddress),
                                  ("pkSeed",       .str km.pkSeed),
                                  ("pkRoot",       .str km.pkRoot),
                                  ("masterEnrolled", .bool masterWrap?.isSome),
                                  ("smartAccountAddress",
                                    match saa? with | some a => .str a | none => .null)
                                ]
                              catch e =>
                                pure <| .error
                                  { code := -32042,
                                    message := "sphincs slot write failed",
                                    data := some (.str e.toString) }
      | _, _, _ => pure (.error invalidParams)
  | "sphincs.account.list" =>
      -- Enumerate hybrid slots on disk. Returns a JSON array of
      -- `{name, paramSet, chainId, ownerAddress, pkSeed, pkRoot,
      --   masterEnrolled, smartAccountAddress?, customPassphrase, createdAt}`
      -- per slot. Best-effort: parse failures on individual files are
      -- swallowed (the slot is omitted from the result) so a single
      -- corrupt file doesn't poison the whole list.
      try
        let names ← LeanCli.Wallet.SphincsHybridStore.listSlotNames
        let mut entries : Array Json := #[]
        for n in names do
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord n with
          | .error _ => pure ()
          | .ok r =>
              let attachJson : Json :=
                LeanCli.Wallet.SphincsHybridStore.ecdsaAttachmentToJson r.ecdsaAttachment
              let smart : Json :=
                match r.smartAccountAddress with
                | some a => .str a
                | none => .null
              entries := entries.push <| .obj #[
                ("name",                .str r.name),
                ("paramSet",            .str r.paramSet.toString),
                ("chainId",             .num (Int.ofNat r.chainId)),
                ("ownerAddress",        .str r.ownerAddress),
                ("ecdsaAttachment",     attachJson),
                ("pkSeed",              .str r.pkSeed),
                ("pkRoot",              .str r.pkRoot),
                ("masterEnrolled",      .bool r.masterWrap.isSome),
                ("smartAccountAddress", smart),
                ("customPassphrase",    .bool r.customPassphrase),
                ("createdAt",           .num (Int.ofNat r.createdAt))
              ]
        pure <| .ok <| .obj #[("accounts", .arr entries)]
      catch e =>
        pure <| .error
          { code := -32043,
            message := "sphincs.account.list failed",
            data := some (.str e.toString) }
  | "sphincs.account.show" =>
      -- Render a single hybrid slot's public state. Mirrors the per-row
      -- shape from `sphincs.account.list`. The sk is never returned.
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error
                { code := -32010, message := "sphincs slot not found",
                  data := some (.str err) }
          | .ok r =>
              let attachJson : Json :=
                LeanCli.Wallet.SphincsHybridStore.ecdsaAttachmentToJson r.ecdsaAttachment
              let smart : Json :=
                match r.smartAccountAddress with
                | some a => .str a
                | none => .null
              pure <| .ok <| .obj #[
                ("name",                .str r.name),
                ("paramSet",            .str r.paramSet.toString),
                ("chainId",             .num (Int.ofNat r.chainId)),
                ("ownerAddress",        .str r.ownerAddress),
                ("ecdsaAttachment",     attachJson),
                ("pkSeed",              .str r.pkSeed),
                ("pkRoot",              .str r.pkRoot),
                ("masterEnrolled",      .bool r.masterWrap.isSome),
                ("smartAccountAddress", smart),
                ("customPassphrase",    .bool r.customPassphrase),
                ("createdAt",           .num (Int.ofNat r.createdAt))
              ]
  | "sphincs.account.computeAddress" =>
      -- eth_call factory.getAddress(owner, pkSeed, pkRoot) → counterfactual
      -- smart-account address. The factory's own view function does the
      -- CREATE2 math, so Lean only assembles the 100-byte calldata and
      -- slices the returned 32-byte word's last 20 bytes. On success, the
      -- on-disk record's `smartAccountAddress` is updated in place; the
      -- next `sphincs.account.show` reads it back without a fresh RPC.
      -- Fails closed when no factory is configured for (chain, paramSet).
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str err) }
          | .ok rec =>
              -- Caller passes `chain` (e.g. "sepolia"); the slot's
              -- `chainId` is the source of truth — if `chain` is omitted
              -- we fall back to a name guess via the policy table.
              let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
              match sphincsFactoryFor cfg chainName rec.paramSet,
                    endpointForChain cfg (some chainName) with
              | .error e, _ | _, .error e =>
                  pure <| .error { code := -32030, message := "sphincs factory/endpoint unavailable", data := some (.str e) }
              | .ok factory, .ok ep =>
                  -- selector(getAddress(address,bytes32,bytes32)) + 3 × 32B
                  match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
                      (LeanCli.Crypto.Hex.encode "getAddress(address,bytes32,bytes32)".toByteArray) with
                  | .error e => pure <| .error { code := -32031, message := "keccak failed", data := some (.str e) }
                  | .ok kh =>
                      -- Concat in ByteArray space then hex-encode once;
                      -- see `tryComputeSmartAccountAddress` for the
                      -- "Hex.encode always prepends 0x" rationale.
                      let selBytes := kh.extract 0 4
                      let ownerBytes : ByteArray :=
                        (LeanCli.Sphincs.UserOp.hexToWord32? rec.ownerAddress).getD ByteArray.empty
                      let pkSeedB : ByteArray :=
                        (LeanCli.Sphincs.UserOp.hexToWord32? rec.pkSeed).getD ByteArray.empty
                      let pkRootB : ByteArray :=
                        (LeanCli.Sphincs.UserOp.hexToWord32? rec.pkRoot).getD ByteArray.empty
                      let dataHex := LeanCli.Crypto.Hex.encode
                        (selBytes ++ ownerBytes ++ pkSeedB ++ pkRootB)
                      match ← LeanCli.RPC.Outbound.ethCall cfg.policy ep factory dataHex "latest" none with
                      | .error e =>
                          pure <| .error { code := -32020, message := "eth_call failed", data := some (.str e) }
                      | .ok ret =>
                          let retHex := (asString ret).getD ""
                          let cleaned : String :=
                            if retHex.startsWith "0x" then (retHex.drop 2).toString else retHex
                          if cleaned.length < 64 then
                            pure <| .error { code := -32032, message := "unexpected returnData", data := some (.str retHex) }
                          else
                            -- last 20 bytes (40 hex chars) of the 32-byte word
                            let addrHex : String :=
                              "0x" ++ String.ofList (cleaned.toList.drop (cleaned.length - 40))
                            try
                              LeanCli.Wallet.SphincsHybridStore.writeRecord
                                { rec with smartAccountAddress := some addrHex }
                            catch _ => pure ()
                            pure <| .ok <| .obj #[
                              ("name", .str name),
                              ("smartAccountAddress", .str addrHex),
                              ("factory", .str factory)
                            ]
  | "sphincs.account.deploy" =>
      -- Build calldata for factory.createAccount(owner, pkSeed, pkRoot)
      -- and submit through the existing EOA pipeline. The deployer EOA
      -- pays gas — picked by the caller via `deployerWallet` + an
      -- optional `deployerAccountIndex` (defaults to 0). On success we
      -- echo the tx hash plus the post-deploy smart-account address
      -- (taken from `rec.smartAccountAddress` if already populated by
      -- `computeAddress`; otherwise the caller should call that first).
      match paramName req.params, paramString req.params "deployerWallet" with
      | .ok name, .ok deployer =>
          let deployerIdx := paramNatD req.params "deployerAccountIndex" 0
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str err) }
          | .ok rec =>
              -- Caller passes `chain` (e.g. "sepolia"); the slot's
              -- `chainId` is the source of truth — if `chain` is omitted
              -- we fall back to a name guess via the policy table.
              let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
              match sphincsFactoryFor cfg chainName rec.paramSet,
                    endpointForChain cfg (some chainName) with
              | .error e, _ | _, .error e =>
                  pure <| .error { code := -32030, message := "sphincs factory/endpoint unavailable", data := some (.str e) }
              | .ok factory, .ok ep =>
                  match ← unlockedSlot state deployer with
                  | .error e => pure (.error e)
                  | .ok dslot =>
                      let cfgEff : Config :=
                        let cid := (LeanCli.RPC.Outbound.chainNameToId chainName).getD cfg.chainId
                        { cfg with rpcEndpoint := ep, chainId := cid }
                      -- Resolve deployer's account index → derivation path & address.
                      match ← LeanCli.Wallet.EoaStore.load deployer with
                      | .error e => pure <| .error { code := -32010, message := "deployer wallet not found", data := some (.str e) }
                      | .ok dRec =>
                          match dRec.accounts.find? (fun a => a.index == deployerIdx) with
                          | none => pure <| .error { code := -32011, message := s!"deployer has no account #{deployerIdx}", data := none }
                          | some dAcct =>
                              match ← derivePrivateKeyFromSeed dslot.seed dAcct.path with
                              | .error e => pure <| .error { code := -32012, message := "deployer key derive failed", data := some (.str e) }
                              | .ok privKey =>
                                  match ← LeanCli.Crypto.Hacl.keccak256EthereumIO
                                      (LeanCli.Crypto.Hex.encode "createAccount(address,bytes32,bytes32)".toByteArray) with
                                  | .error e => pure <| .error { code := -32031, message := "keccak failed", data := some (.str e) }
                                  | .ok kh =>
                                      let sel := LeanCli.Crypto.Hex.encode (kh.extract 0 4)
                                      let ownerB := (LeanCli.Sphincs.UserOp.hexToWord32? rec.ownerAddress).getD ByteArray.empty
                                      let pkSeedB := (LeanCli.Sphincs.UserOp.hexToWord32? rec.pkSeed).getD ByteArray.empty
                                      let pkRootB := (LeanCli.Sphincs.UserOp.hexToWord32? rec.pkRoot).getD ByteArray.empty
                                      let selBytes := (LeanCli.Crypto.Hex.decode sel).getD ByteArray.empty
                                      let dataBytes := selBytes ++ ownerB ++ pkSeedB ++ pkRootB
                                      let dslot' := { dslot with address := dAcct.address, derivationPath := dAcct.path }
                                      match LeanCli.Ethereum.Address.fromHex factory with
                                      | none => pure (.error invalidParams)
                                      | some factoryAddr =>
                                          let via? ← verifiedReadVia state cfgEff.chainId cfgEff.rpcEndpoint
                                          match ← buildSignBroadcastTx cfgEff dslot' privKey factory factoryAddr 0 dataBytes none none via? with
                                          | .error e => pure (.error e)
                                          | .ok j =>
                                              -- Echo the slot's smart-account address (set by
                                              -- `computeAddress` ahead of time when possible).
                                              let saa : Json :=
                                                match rec.smartAccountAddress with
                                                | some a => .str a
                                                | none => .null
                                              pure <| .ok <| .obj #[
                                                ("name", .str name),
                                                ("factory", .str factory),
                                                ("smartAccountAddress", saa),
                                                ("tx", j)
                                              ]
      | _, _ => pure (.error invalidParams)
  | "sphincs.account.send" =>
      -- Submit a UserOperation from a hybrid SPHINCS- account through the
      -- configured bundler. The signature field is `abi.encode(bytes
      -- ecdsaSig, bytes sphincsSig)` matching the on-chain
      -- `_validateSignature` decoder. The pipeline (sk unlock, ECDSA
      -- derive, gas estimate, dual-sign, submit) lives in
      -- `executeSphincsUserOp`; this RPC only assembles the `execute(...)`
      -- callData from {to, value, data} before delegating.
      --
      -- `valueEth` (decimal ETH, the canonical human-readable form, e.g.
      -- "0.001") is preferred when present; `value` (wei — decimal Nat
      -- or 0x-hex) stays as a fallback for power-users / scripted
      -- callers. Parser conversion lives in `LeanCli.Util.Units` so
      -- the TUI stays a thin RPC forwarder.
      match paramName req.params, paramString req.params "to" with
      | .ok name, .ok toStr =>
          let valueWei : Nat :=
            match paramString req.params "valueEth" with
            | .ok ethStr =>
                (LeanCli.Util.Units.parseUnits ethStr 18).getD 0
            | .error _ =>
                match paramString req.params "value" with
                | .ok valueStr =>
                    (valueStr.toNat?).getD ((parseHexQuantity valueStr).getD 0)
                | .error _ => 0
          let dataHex := paramStringD req.params "data" "0x"
          let userData : ByteArray :=
            (LeanCli.Crypto.Hex.decode dataHex).getD ByteArray.empty
          -- Pre-sign guard: refuse a zero-value, empty-calldata userOp.
          -- `execute(to, 0, 0x)` carries no intent — it reverts on-chain
          -- and burns gas (the failure this guard exists to prevent). The
          -- self-batch path below always has non-empty executeBatch
          -- calldata, so it never trips this.
          if isNoOpCall valueWei userData then
            pure <| .error (noOpCallError toStr)
          else
          -- Pre-sign address-integrity gate (same as eoa.send): refuse to
          -- sign when `to` or an address embedded in the calldata is a
          -- near-miss to one of the daemon's own addresses. `dataHex`
          -- here is the raw user calldata (or the executeBatch envelope
          -- for the self-batch path), so the inner address words are
          -- scanned either way.
          match ← LeanCli.Daemon.Server.AddrGuard.enforce req.params toStr dataHex with
          | .error e => pure (.error e)
          | .ok () =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              -- Self-directed `executeBatch(...)` detection: when `to` is
              -- the smart account itself AND the calldata's selector is
              -- `executeBatch((address,uint256,bytes)[])` (0x34fcd5be —
              -- e.g. the batched frame from `Aave.Prepare.maybeBatch`), the
              -- executeBatch calldata MUST be the UserOp callData directly:
              -- the EntryPoint calls `executeBatch`, so `msg.sender ==
              -- entryPoint` and the account's `_requireForExecute` gate
              -- passes. Wrapping it in `execute(self, 0, …)` would self-call
              -- `executeBatch` with `msg.sender == address(this)`, which the
              -- contract rejects. Any other call keeps the standard
              -- `execute(to,value,data)` wrap. (New surfaces should prefer
              -- `sphincs.account.sendBatch` with raw legs; this keeps the
              -- legacy single-frame batch path — used by the agent's Aave
              -- auto-batch — broadcasting correctly.)
              let isSelfBatch :=
                (match rec.smartAccountAddress with
                 | some sa => sa.toLower == toStr.toLower
                 | none     => false)
                && dataHex.toLower.startsWith ("0x" ++ LeanCli.Wallet.ExecuteBatch.selExecuteBatch)
              let callData :=
                if isSelfBatch then userData
                else Sphincs.Send.buildExecuteCalldata toStr valueWei userData
              let jm := if isSelfBatch then "sphincs.userOp.batch" else "sphincs.userOp"
              match ← executeSphincsUserOp cfg state notify rec callData toStr valueWei userData
                  req.params (journalMethod := jm) with
              | .error e => pure (.error e)
              | .ok j =>
                  -- Echo the slot name on top of the helper's result.
                  let withName : Json := match j with
                    | .obj fields => .obj (fields.push ("name", .str name))
                    | _ => j
                  pure (.ok withName)
      | _, _ => pure (.error invalidParams)
  | "sphincs.account.sendBatch" =>
      -- Submit ONE UserOperation that executes a list of calls atomically
      -- via `SphincsAccount.executeBatch((address,uint256,bytes)[])`. The
      -- UserOp's callData IS the executeBatch envelope directly (NOT
      -- wrapped in `execute(...)`): the EntryPoint calls `executeBatch`, so
      -- `msg.sender == entryPoint` and the contract's `_requireForExecute`
      -- gate passes. Wrapping in `execute(self, 0, …)` would make the
      -- account self-call executeBatch with `msg.sender == address(this)`,
      -- which that gate rejects (the single-call `execute` path is fine
      -- self-called; `executeBatch` is entryPoint-only).
      --
      -- `legs` is `[{to, value|valueEth, data}, …]`. Each leg's intent is
      -- decoded + simulated by the caller (TUI batch flow) before this RPC
      -- is reached; the signature still terminates at ConfirmGate.
      match paramName req.params, parseBatchLegs req.params with
      | .ok name, some calls =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none =>
                  pure <| .error
                    { code := -32033,
                      message := "smartAccountAddress unset — run sphincs.account.computeAddress (or .deploy) first",
                      data := none }
              | some sender =>
                  -- callData = executeBatch(Call[]) directly = the UserOp callData.
                  let batchHex := LeanCli.Wallet.ExecuteBatch.encodeExecuteBatch calls
                  let callData := (LeanCli.Crypto.Hex.decode batchHex).getD ByteArray.empty
                  let totalValue := calls.foldl (fun acc c => acc + c.value) 0
                  -- Same pre-sign address-integrity gate as the single
                  -- send path. `batchHex` is an executeBatch envelope, so
                  -- the guard scans address-shaped words at any byte offset
                  -- to catch inner call data embedded in dynamic bytes.
                  match ← LeanCli.Daemon.Server.AddrGuard.enforce req.params sender batchHex with
                  | .error e => pure (.error e)
                  | .ok () =>
                      -- Journal the self-directed batch: to = the account,
                      -- data = the executeBatch envelope, value = Σ leg values.
                      match ← executeSphincsUserOp cfg state notify rec callData
                          sender totalValue callData req.params
                          (journalMethod := "sphincs.userOp.batch") with
                      | .error e => pure (.error e)
                      | .ok j =>
                          let withMeta : Json := match j with
                            | .obj fields =>
                                .obj ((fields.push ("name", .str name)).push
                                  ("legs", .num (Int.ofNat calls.length)))
                            | _ => j
                          pure (.ok withMeta)
      | _, _ =>
          pure <| .error
            { code := -32602,
              message := "sendBatch: requires `name` and a non-empty `legs` array (each leg needs a string `to`)",
              data := none }
  | "sphincs.account.encodeBatch" =>
      -- Pure preview/sim helper: encode `legs` into the
      -- `executeBatch((address,uint256,bytes)[])` calldata that
      -- `sendBatch` would submit as the UserOp callData, WITHOUT signing
      -- or broadcasting. Returns `{ to, data, totalValue, legs }` where
      -- `to` is the smart account itself (the EntryPoint calls
      -- `executeBatch` on it). The TUI batch flow simulates this
      -- `{to, data}` with `from = entryPoint` to show an aggregate outcome
      -- in ConfirmGate. Keeping the ABI encoding in verified Lean means
      -- the TUI never re-implements (and never diverges from) the encoder.
      match paramName req.params, parseBatchLegs req.params with
      | .ok name, some calls =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none =>
                  pure <| .error
                    { code := -32033,
                      message := "smartAccountAddress unset — run sphincs.account.computeAddress (or .deploy) first",
                      data := none }
              | some sender =>
                  let batchHex := LeanCli.Wallet.ExecuteBatch.encodeExecuteBatch calls
                  let totalValue := calls.foldl (fun acc c => acc + c.value) 0
                  pure <| .ok <| .obj #[
                    ("to", .str sender),
                    ("data", .str batchHex),
                    ("totalValue", .str (toString totalValue)),
                    ("entryPoint", .str Sphincs.Send.entryPointV09Address),
                    ("legs", .num (Int.ofNat calls.length))
                  ]
      | _, _ =>
          pure <| .error
            { code := -32602,
              message := "encodeBatch: requires `name` and a non-empty `legs` array (each leg needs a string `to`)",
              data := none }
  | "sphincs.account.rotateOwner" =>
      -- Submit a UserOp that calls `SphincsAccount.rotateOwner(newOwner)`.
      -- The on-chain contract gates this on the EntryPoint OR self-call;
      -- we wrap the rotate calldata in `execute(self, 0, rotateData)` so
      -- the EntryPoint forwards through the account, producing the
      -- `address(this)` self-call branch. The local store is NOT updated
      -- automatically — the caller must reconfigure the slot (or its
      -- `ecdsaAttachment`) after confirming the userOp succeeded on-chain
      -- via `sphincs.account.getUserOp`.
      match paramName req.params, paramString req.params "newOwner" with
      | .ok name, .ok newOwner =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none => pure <| .error { code := -32033, message := "smartAccountAddress unset", data := none }
              | some sender =>
                  match ← Sphincs.Send.buildRotateOwnerCalldata newOwner with
                  | .error e => pure <| .error { code := -32035, message := "rotateOwner calldata build failed", data := some (.str e) }
                  | .ok rotateData =>
                      -- rotateOwner is a self-call: execute(self, 0, rotateData).
                      let callData := Sphincs.Send.buildExecuteCalldata sender 0 rotateData
                      match ← executeSphincsUserOp cfg state notify rec callData sender 0 rotateData req.params with
                      | .error e => pure (.error e)
                      | .ok j =>
                          let withFields : Json := match j with
                            | .obj fs =>
                                .obj (fs.push ("name", .str name)
                                        |>.push ("newOwner", .str newOwner))
                            | _ => j
                          pure (.ok withFields)
      | _, _ => pure (.error invalidParams)
  | "sphincs.account.encodeRotateOwner" =>
      -- Returns the raw rotateOwner(address) ABI calldata plus the
      -- slot's smart-account address. Lets the TUI route rotations
      -- through SendRawFlow's ConfirmGate before broadcast: the gate
      -- needs the to/value/data shape that the simulator can eth_call.
      -- The daemon's sphincs.account.send then wraps this calldata in
      -- execute(self, 0, calldata) at signing time, identical to what
      -- the older sphincs.account.rotateOwner RPC did internally.
      match paramName req.params, paramString req.params "newOwner" with
      | .ok name, .ok newOwner =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error e => pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none => pure <| .error { code := -32033, message := "smartAccountAddress unset", data := none }
              | some sender =>
                  match ← Sphincs.Send.buildRotateOwnerCalldata newOwner with
                  | .error e => pure <| .error { code := -32035, message := "rotateOwner calldata build failed", data := some (.str e) }
                  | .ok rotateData =>
                      pure <| .ok <| .obj #[
                        ("name", .str name),
                        ("newOwner", .str newOwner),
                        ("smartAccountAddress", .str sender),
                        ("calldata", .str (LeanCli.Crypto.Hex.encode rotateData)) ]
      | _, _ => pure (.error invalidParams)
  | "sphincs.bundler.show" =>
      -- Returns the bundler URL the daemon will use for sphincs userOps,
      -- with the same chain-resolution priority as the poll RPC:
      --   1. explicit `chain` param
      --   2. the slot's chainId (when `name` is supplied)
      --   3. daemon's default chainId
      -- The URL is sourced from `cfg.sphincsBundlers`, which is seeded
      -- from `daemon.json` -> `sphincs_bundlers` (or built-in defaults).
      -- To override at runtime, edit daemon.json and restart.
      let slotChain? : IO (Option String) := do
        match paramName req.params with
        | .error _ => pure none
        | .ok slotName =>
            match ← LeanCli.Wallet.SphincsHybridStore.readRecord slotName with
            | .ok rec => pure (some (chainNameGuess rec.chainId))
            | .error _ => pure none
      let chainName ← do
        match paramString req.params "chain" with
        | .ok c => pure c
        | .error _ =>
            match ← slotChain? with
            | some c => pure c
            | none => pure (chainNameGuess cfg.chainId)
      let bundler : Json := match sphincsBundlerFor cfg chainName with
        | .ok url => .str url
        | .error _ => .null
      pure <| .ok <| .obj #[
        ("chain", .str chainName),
        ("bundler", bundler),
        ("source", .str "daemon.json or built-in default; edit daemon.json under sphincs_bundlers to override")
      ]
  | "sphincs.account.commitRotation" =>
      -- Atomically rewrite a sphincs-hybrid slot's `ecdsaAttachment`
      -- and `ownerAddress` to match a NEW owner address. Call this
      -- AFTER `sphincs.account.rotateOwner` succeeded on-chain (i.e.
      -- after `sphincs.account.getUserOp` returned a receipt with
      -- success=true). Verifies the on-chain `owner()` view to refuse
      -- desyncing the slot when the rotation never landed.
      --
      -- Params:
      --   name                 : sphincs slot name
      --   newOwner             : new owner address (must equal on-chain owner())
      --   newWalletName        : EOA wallet that owns newOwner
      --   newAccountIndex      : optional (default 0); wallet's accounts[idx].address
      --                          must equal newOwner
      match paramName req.params,
            paramString req.params "newOwner",
            paramString req.params "newWalletName" with
      | .ok name, .ok newOwner, .ok newWalletName =>
          let newIdx : Nat := (getField "newAccountIndex" req.params >>= asNat).getD 0
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error e =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match ← LeanCli.Wallet.EoaStore.load newWalletName with
              | .error e =>
                  pure <| .error { code := -32010, message := "newWalletName not found", data := some (.str e) }
              | .ok wRec =>
                  match wRec.accounts.find? (fun a => a.index == newIdx) with
                  | none =>
                      pure <| .error { code := -32602, message := s!"wallet has no account #{newIdx}", data := none }
                  | some acct =>
                      let walletAddr := acct.address.toLower
                      let claimedAddr := newOwner.toLower
                      if walletAddr ≠ claimedAddr then
                        pure <| .error
                          { code := -32602,
                            message := "newWalletName/newAccountIndex does not own newOwner",
                            data := some (.str s!"wallet[#{newIdx}]={walletAddr} but newOwner={claimedAddr}") }
                      else
                        -- Verify on-chain owner matches.
                        match rec.smartAccountAddress with
                        | none => pure <| .error { code := -32033, message := "smartAccountAddress unset", data := none }
                        | some sender =>
                            let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
                            match endpointForChain cfg (some chainName) with
                            | .error e => pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
                            | .ok ep =>
                                -- owner() selector = keccak256("owner()")[:4] = 0x8da5cb5b
                                match ← LeanCli.RPC.Outbound.call cfg.policy ep
                                    .call (.arr #[.obj #[("to", .str sender), ("data", .str "0x8da5cb5b")], .str "latest"]) none with
                                | .error e => pure <| .error { code := -32020, message := "owner() call failed", data := some (.str e) }
                                | .ok r =>
                                    let onChainHex := (asString r).getD "0x"
                                    -- Last 20 bytes of the returned 32-byte word.
                                    let stripped := if onChainHex.startsWith "0x" then onChainHex.drop 2 else onChainHex.toSlice
                                    let raw := stripped.toString.toLower
                                    let onChainOwner :=
                                      if raw.length >= 40 then "0x" ++ (raw.drop (raw.length - 40)) else ""
                                    if onChainOwner ≠ claimedAddr then
                                      pure <| .error
                                        { code := -32034,
                                          message := "on-chain owner does not match newOwner; rotation didn't land?",
                                          data := some (.str s!"chain owner={onChainOwner} but newOwner={claimedAddr}") }
                                    else
                                      -- The SPHINCS sk wrap's AAD binds to
                                      -- `(name, paramSet, ownerAddress)` — see
                                      -- `SphincsHybridStore.aad` — so changing
                                      -- ownerAddress without re-wrapping
                                      -- would invalidate every unlock path.
                                      -- Unwrap the sk via master OR
                                      -- per-slot, then re-seal both wraps
                                      -- under the new AAD.
                                      --
                                      -- Recovery mode: an earlier buggy
                                      -- version of this RPC rewrote
                                      -- ownerAddress without re-wrapping.
                                      -- If the caller passes `oldOwner`,
                                      -- we override the AAD on the
                                      -- unwrap side so we can decrypt
                                      -- the original wrap and then
                                      -- re-seal cleanly. Once recovery
                                      -- runs once, the slot's wrap AAD
                                      -- matches rec.ownerAddress again
                                      -- and oldOwner is no longer needed.
                                      let oldOwner? := (paramString req.params "oldOwner").toOption
                                      let unwrapRec : LeanCli.Wallet.SphincsHybridStore.Record :=
                                        match oldOwner? with
                                        | some oo => { rec with ownerAddress := oo }
                                        | none => rec
                                      let masterSlot? ← LeanCli.Daemon.State.getMasterKek? state
                                      let unlockExc : IO (Except String String) := do
                                        match masterSlot? with
                                        | some mslot =>
                                            match ← LeanCli.Wallet.SphincsHybridStore.openWithMaster mslot.kek unwrapRec with
                                            | .ok skHex => pure (.ok skHex)
                                            | .error _ =>
                                                -- Master path failed (e.g.
                                                -- slot pre-dates master
                                                -- enrolment). Fall back to
                                                -- per-slot passphrase if
                                                -- provided.
                                                match paramString req.params "passphrase" with
                                                | .ok pp => LeanCli.Wallet.SphincsHybridStore.openSk unwrapRec pp
                                                | _ => pure (.error "master path failed and no per-slot passphrase provided")
                                        | none =>
                                            match paramString req.params "passphrase" with
                                            | .ok pp => LeanCli.Wallet.SphincsHybridStore.openSk unwrapRec pp
                                            | _ => pure (.error "no master KEK loaded and no per-slot passphrase provided")
                                      match ← unlockExc with
                                      | .error e =>
                                          pure <| .error
                                            { code := -32011,
                                              message := "sphincs sk unlock failed (needed to re-seal under new owner AAD)",
                                              data := some (.str e) }
                                      | .ok skHex =>
                                          -- Mint a fresh ephemeral
                                          -- passphrase for the new
                                          -- per-slot wrap. Same shape as
                                          -- `sphincs.account.create`'s
                                          -- non-customPassphrase path.
                                          let newPpBytes ← LeanCli.Crypto.Random.getRandomBytes 32
                                          let newPp :=
                                            if rec.customPassphrase then
                                              -- Caller must supply passphrase
                                              -- for slots they manage; reuse
                                              -- it for the new wrap.
                                              (paramString req.params "passphrase").toOption.getD
                                                (LeanCli.Crypto.Hex.encode newPpBytes)
                                            else LeanCli.Crypto.Hex.encode newPpBytes
                                          let newKdfSalt ← LeanCli.Crypto.Random.getRandomBytes 16
                                          let newIters := LeanCli.Wallet.SphincsHybridStore.defaultKdfIters
                                          match ← LeanCli.Wallet.SphincsHybridStore.sealSk
                                              rec.name rec.paramSet newOwner newPp skHex
                                              newKdfSalt newIters with
                                          | .error err =>
                                              pure <| .error
                                                { code := -32041,
                                                  message := "sphincs sk re-seal failed",
                                                  data := some (.str err) }
                                          | .ok newPpCt =>
                                              let newMasterWrap? : Option ByteArray ← match masterSlot? with
                                                | none => pure none
                                                | some mslot =>
                                                    match ← LeanCli.Wallet.SphincsHybridStore.sealUnderMaster
                                                        mslot.kek rec.name rec.paramSet newOwner skHex with
                                                    | .ok w => pure (some w)
                                                    | .error _ => pure none
                                              let updated : LeanCli.Wallet.SphincsHybridStore.Record :=
                                                { rec with
                                                  ownerAddress := newOwner,
                                                  ecdsaAttachment :=
                                                    LeanCli.Wallet.Account.EcdsaAttachment.existing newWalletName newIdx,
                                                  kdfSalt := newKdfSalt,
                                                  kdfIters := newIters,
                                                  passphraseCiphertext := newPpCt,
                                                  masterWrap := newMasterWrap? }
                                              LeanCli.Wallet.SphincsHybridStore.writeRecord updated
                                              pure <| .ok <| .obj #[
                                                ("name", .str name),
                                                ("newOwner", .str newOwner),
                                                ("newWalletName", .str newWalletName),
                                                ("newAccountIndex", .num (Int.ofNat newIdx)),
                                                ("onChainOwnerVerified", .bool true),
                                                ("rewrappedMaster", .bool newMasterWrap?.isSome) ]
      | _, _, _ => pure (.error invalidParams)
  | "sphincs.account.resyncOwner" =>
      -- Idempotent owner reconciliation. Reads on-chain `owner()` and
      -- compares to the slot's local `rec.ownerAddress`. If they differ
      -- AND the on-chain owner is one of our local EOA accounts AND
      -- master KEK is loaded, rewraps the SPHINCS sk under the new AAD
      -- and writes the updated slot atomically. Otherwise no-op with a
      -- descriptive status code.
      --
      -- Replaces the brittle TUI-side auto-commit (which only fired when
      -- the user happened to be on the poll-run screen at the moment
      -- the bundler reported inclusion). The TUI now calls this on
      -- every detail-panel entry — if a rotation lands while the user
      -- is anywhere else in the app, the next visit picks it up.
      --
      -- customPassphrase slots return `drift-master-locked` because we
      -- can't open them without the per-slot passphrase; those users
      -- have to call `sphincs.account.commitRotation` manually.
      match paramName req.params with
      | .error e => pure (.error e)
      | .ok name =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error e =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str e) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none =>
                  pure <| .ok <| .obj #[
                    ("name", .str name),
                    ("status", .str "no-smart-account-address") ]
              | some sender =>
                  let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
                  match endpointForChain cfg (some chainName) with
                  | .error e =>
                      pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
                  | .ok ep =>
                      -- owner() selector = keccak256("owner()")[:4] = 0x8da5cb5b
                      match ← LeanCli.RPC.Outbound.call cfg.policy ep
                          .call (.arr #[.obj #[("to", .str sender), ("data", .str "0x8da5cb5b")], .str "latest"]) none with
                      | .error e =>
                          pure <| .error { code := -32020, message := "owner() call failed", data := some (.str e) }
                      | .ok r =>
                          let onChainHex := (asString r).getD "0x"
                          let stripped := if onChainHex.startsWith "0x" then onChainHex.drop 2 else onChainHex.toSlice
                          let raw := stripped.toString.toLower
                          let onChainOwner :=
                            if raw.length >= 40 then "0x" ++ (raw.drop (raw.length - 40)) else ""
                          if onChainOwner = "" then
                            pure <| .ok <| .obj #[
                              ("name", .str name),
                              ("status", .str "owner-call-empty") ]
                          else if onChainOwner = rec.ownerAddress.toLower then
                            pure <| .ok <| .obj #[
                              ("name", .str name),
                              ("status", .str "in-sync"),
                              ("owner", .str rec.ownerAddress) ]
                          else
                            -- Drift detected. Look up the on-chain owner in our local EOA slots.
                            let target := onChainOwner
                            let names ← LeanCli.Wallet.EoaStore.list
                            let rec scanForOwner : List String → IO (Option (String × Nat))
                              | [] => pure none
                              | n :: rest => do
                                  match ← LeanCli.Wallet.EoaStore.load n with
                                  | .error _ => scanForOwner rest
                                  | .ok wr =>
                                      let accts := recordAccounts wr
                                      match accts.find? (fun a => a.address.toLower = target) with
                                      | some a => pure (some (n, a.index))
                                      | none => scanForOwner rest
                            match ← scanForOwner names with
                            | none =>
                                pure <| .ok <| .obj #[
                                  ("name", .str name),
                                  ("status", .str "drift-no-local-key"),
                                  ("onChainOwner", .str onChainOwner),
                                  ("localOwner", .str rec.ownerAddress) ]
                            | some (walletName, idx) =>
                                -- We have a local key for the new on-chain owner. Try to rewrap.
                                let masterSlot? ← LeanCli.Daemon.State.getMasterKek? state
                                match masterSlot? with
                                | none =>
                                    pure <| .ok <| .obj #[
                                      ("name", .str name),
                                      ("status", .str "drift-master-locked"),
                                      ("onChainOwner", .str onChainOwner),
                                      ("newWalletName", .str walletName),
                                      ("newAccountIndex", .num (Int.ofNat idx)),
                                      ("hint", .str "unlock master keystore and retry, or call sphincs.account.commitRotation with passphrase") ]
                                | some mslot =>
                                    match ← LeanCli.Wallet.SphincsHybridStore.openWithMaster mslot.kek rec with
                                    | .error err =>
                                        pure <| .ok <| .obj #[
                                          ("name", .str name),
                                          ("status", .str "drift-unwrap-failed"),
                                          ("onChainOwner", .str onChainOwner),
                                          ("error", .str err) ]
                                    | .ok skHex =>
                                        let newPpBytes ← LeanCli.Crypto.Random.getRandomBytes 32
                                        let newPp := LeanCli.Crypto.Hex.encode newPpBytes
                                        let newKdfSalt ← LeanCli.Crypto.Random.getRandomBytes 16
                                        let newIters := LeanCli.Wallet.SphincsHybridStore.defaultKdfIters
                                        match ← LeanCli.Wallet.SphincsHybridStore.sealSk
                                            rec.name rec.paramSet onChainOwner newPp skHex
                                            newKdfSalt newIters with
                                        | .error err =>
                                            pure <| .error { code := -32041, message := "sphincs sk re-seal failed", data := some (.str err) }
                                        | .ok newPpCt =>
                                            match ← LeanCli.Wallet.SphincsHybridStore.sealUnderMaster
                                                mslot.kek rec.name rec.paramSet onChainOwner skHex with
                                            | .error err =>
                                                pure <| .error { code := -32041, message := "master re-seal failed", data := some (.str err) }
                                            | .ok newMasterWrap =>
                                                let updated : LeanCli.Wallet.SphincsHybridStore.Record :=
                                                  { rec with
                                                      ownerAddress := onChainOwner,
                                                      ecdsaAttachment :=
                                                        LeanCli.Wallet.Account.EcdsaAttachment.existing walletName idx,
                                                      kdfSalt := newKdfSalt,
                                                      kdfIters := newIters,
                                                      passphraseCiphertext := newPpCt,
                                                      masterWrap := some newMasterWrap }
                                                LeanCli.Wallet.SphincsHybridStore.writeRecord updated
                                                pure <| .ok <| .obj #[
                                                  ("name", .str name),
                                                  ("status", .str "resynced"),
                                                  ("newOwner", .str onChainOwner),
                                                  ("newWalletName", .str walletName),
                                                  ("newAccountIndex", .num (Int.ofNat idx)) ]
  | "sphincs.account.deployStatus" =>
      -- Probe eth_getCode at the slot's smart-account address. Empty
      -- bytecode → not deployed (factory.createAccount hasn't run, or
      -- first-send-also-deploy initCode hasn't been bundled yet). Used
      -- by the TUI to gate the "Deploy" action once the account is
      -- already on chain.
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
          | .error err =>
              pure <| .error { code := -32010, message := "sphincs slot not found", data := some (.str err) }
          | .ok rec =>
              match rec.smartAccountAddress with
              | none =>
                  -- No counterfactual computed yet → certainly not deployed.
                  pure <| .ok <| .obj #[
                    ("name",                .str name),
                    ("smartAccountAddress", .null),
                    ("deployed",            .bool false),
                    ("codeLen",             .num 0)
                  ]
              | some sender =>
                  let chainName := paramStringD req.params "chain" (chainNameGuess rec.chainId)
                  match endpointForChain cfg (some chainName) with
                  | .error e => pure <| .error { code := -32021, message := "unknown chain", data := some (.str e) }
                  | .ok ep =>
                      match ← LeanCli.RPC.Outbound.call cfg.policy ep
                          .getCode (.arr #[.str sender, .str "latest"]) none with
                      | .error e => pure <| .error { code := -32020, message := "eth_getCode failed", data := some (.str e) }
                      | .ok r =>
                          let codeHex := (asString r).getD "0x"
                          let stripped := if codeHex.startsWith "0x" then (codeHex.drop 2).toString else codeHex
                          let codeLen := stripped.length / 2
                          pure <| .ok <| .obj #[
                            ("name",                .str name),
                            ("smartAccountAddress", .str sender),
                            ("deployed",            .bool (codeLen > 0)),
                            ("codeLen",             .num (Int.ofNat codeLen))
                          ]
  | "sphincs.factory.deploy" =>
      -- Sepolia-only one-shot factory deploy via the bundled shell.
      -- Params:
      --   paramSet           : "SLH-DSA-SHA2-128-24" | "C13"
      --   chain              : must be "sepolia" (mainnet refused — no factory
      --                        has been deployed yet at the time of writing)
      --   deployerWallet     : EOA slot to fund the deploy
      --   deployerPassphrase : (optional if master KEK loaded) passphrase
      --   deployerAccountIndex : optional (default 0)
      match paramString req.params "paramSet",
            paramString req.params "deployerWallet" with
      | .ok psStr, .ok deployer =>
          let chain := paramStringD req.params "chain" "sepolia"
          if chain ≠ "sepolia" then
            pure <| .error
              { code := -32036,
                message := "sphincs factory deploy is Sepolia-only (no mainnet factory yet)",
                data := some (.str s!"got chain={chain}") }
          else match LeanCli.Sphincs.ParamSet.parse? psStr with
          | none =>
              pure <| .error { invalidParams with data := some (.str s!"unknown paramSet: {psStr}") }
          | some ps =>
              match sphincsVerifierFor cfg chain ps with
              | .error e =>
                  pure <| .error { code := -32030, message := "verifier unavailable", data := some (.str e) }
              | .ok verifierAddr =>
                  match ← LeanCli.Wallet.EoaStore.load deployer with
                  | .error e => pure <| .error { code := -32010, message := "deployer wallet not found", data := some (.str e) }
                  | .ok dRec =>
                      let idx := paramNatD req.params "deployerAccountIndex" 0
                      match dRec.accounts.find? (fun a => a.index == idx) with
                      | none => pure <| .error { code := -32011, message := s!"deployer has no account #{idx}", data := none }
                      | some dAcct =>
                          let seedExc : IO (Except String ByteArray) := do
                            -- Prefer master KEK (slot may have lazy-enrolled);
                            -- fall back to the explicit `deployerPassphrase`.
                            match ← LeanCli.Daemon.State.getMasterKek? state with
                            | some mslot =>
                                match ← LeanCli.Keystore.MasterPassphrase.unwrapSlot
                                    mslot.kek dRec.name dRec.derivationPath dRec.address
                                    (dRec.masterWrap.getD ByteArray.empty) with
                                | .ok seed => pure (.ok seed)
                                | .error _ =>
                                    match paramString req.params "deployerPassphrase" with
                                    | .error _ => pure (.error "deployerPassphrase required (master path failed)")
                                    | .ok pp =>
                                        match ← LeanCli.Wallet.EoaStore.unlockSeedIO dRec pp with
                                        | .ok seed => pure (.ok seed)
                                        | .error e => pure (.error e)
                            | none =>
                                match paramString req.params "deployerPassphrase" with
                                | .error _ => pure (.error "deployerPassphrase required (master KEK not loaded)")
                                | .ok pp =>
                                    match ← LeanCli.Wallet.EoaStore.unlockSeedIO dRec pp with
                                    | .ok seed => pure (.ok seed)
                                    | .error e => pure (.error e)
                          match ← seedExc with
                          | .error e => pure <| .error { code := -32011, message := "deployer unlock failed", data := some (.str e) }
                          | .ok seed =>
                              match ← derivePrivateKeyFromSeed seed dAcct.path with
                              | .error e => pure <| .error { code := -32012, message := "deployer key derive failed", data := some (.str e) }
                              | .ok pk =>
                                  -- Hex.encode is `0x`-prefixed; forge expects no extra prefix.
                                  let pkHex := LeanCli.Crypto.Hex.encode pk
                                  try
                                    let out ← IO.Process.output {
                                      cmd := "./ops/scripts/sphincs_sepolia.sh",
                                      args := #["deploy", ps.toString],
                                      env := #[
                                        ("SPHINCS_VERIFIER_ADDR", some verifierAddr),
                                        ("SEPOLIA_DEPLOYER_PRIVATE_KEY", some pkHex),
                                        ("PRIVATE_KEY", some pkHex)
                                      ]
                                    }
                                    -- Best-effort: grep the address out of stdout.
                                    let stdout := out.stdout
                                    let lines := stdout.splitOn "\n"
                                    let factory? : Option String := lines.findSome? fun l =>
                                      let t := l.trimAscii.toString
                                      if t.startsWith "Deployed to:" then
                                        some (((t.drop 12).trimAscii).toString)
                                      else none
                                    pure <| .ok <| .obj #[
                                      ("paramSet", .str ps.toString),
                                      ("chain", .str chain),
                                      ("verifier", .str verifierAddr),
                                      ("factory", match factory? with | some a => .str a | none => .null),
                                      ("exitCode", .num (Int.ofNat out.exitCode.toNat)),
                                      ("stdout", .str stdout),
                                      ("stderr", .str out.stderr)
                                    ]
                                  catch e =>
                                    pure <| .error { code := -32037, message := "deploy script failed to spawn", data := some (.str e.toString) }
      | _, _ => pure (.error invalidParams)
  | "sphincs.bundler.check" =>
      -- Cheap pre-flight: call `eth_supportedEntryPoints` against the
      -- configured bundler and report whether the v0.9 EntryPoint
      -- singleton appears. Useful for catching a bundler that only
      -- speaks v0.6/v0.7 before any signing happens. Does not gate the
      -- send pipeline — different bundlers respond inconsistently (some
      -- return empty arrays) so we leave the policy decision to the
      -- caller, just surface the raw signal.
      let chainName := paramStringD req.params "chain" (chainNameGuess cfg.chainId)
      match sphincsBundlerFor cfg chainName with
      | .error e => pure <| .error { code := -32030, message := "sphincs bundler unavailable", data := some (.str e) }
      | .ok bundlerUrl =>
          match ← Sphincs.Send.bundlerCall bundlerUrl "eth_supportedEntryPoints" (.arr #[]) with
          | .error e => pure <| .error { code := -32021, message := "bundler error", data := some (.str e) }
          | .ok r =>
              let lowered (s : String) : String := s.toLower
              let v09 : String := lowered Sphincs.Send.entryPointV09Address
              let supports : Bool :=
                match r with
                | .arr xs => xs.any (fun j =>
                    match asString j with
                    | some s => lowered s = v09
                    | none => false)
                | _ => false
              pure <| .ok <| .obj #[
                ("bundler", .str bundlerUrl),
                ("v09EntryPoint", .str Sphincs.Send.entryPointV09Address),
                ("supported", .bool supports),
                ("raw", r)
              ]
  | "sphincs.account.getUserOp" =>
      -- Read-through to the bundler's `eth_getUserOperationReceipt`,
      -- which is the spec-authoritative "is this userOp mined" query
      -- (returns null until included, then a receipt with
      -- transactionHash + success). We also try
      -- `eth_getUserOperationByHash` as a side-channel; some bundlers
      -- (notably Candide) return the userOp+blockHash from that method
      -- even before the receipt is fully populated. Either non-null
      -- result is surfaced to the TUI as "included".
      match paramString req.params "userOpHash" with
      | .error e => pure (.error e)
      | .ok userOpHash =>
          -- Chain resolution priority:
          --   1. explicit `chain` param from the caller (TUI)
          --   2. the slot's stored chainId (when `name` is supplied)
          --   3. the daemon's default cfg.chainId
          -- (3) is the wrong default for sphincs slots because the
          -- daemon may default to mainnet while every sphincs slot
          -- right now lives on Sepolia — surfacing as
          -- "no sphincs bundler configured for chain 'mainnet'".
          let slotChain? : IO (Option String) := do
            match paramName req.params with
            | .error _ => pure none
            | .ok slotName =>
                match ← LeanCli.Wallet.SphincsHybridStore.readRecord slotName with
                | .ok rec => pure (some (chainNameGuess rec.chainId))
                | .error _ => pure none
          let chainName ← do
            match paramString req.params "chain" with
            | .ok c => pure c
            | .error _ =>
                match ← slotChain? with
                | some c => pure c
                | none => pure (chainNameGuess cfg.chainId)
          match sphincsBundlerFor cfg chainName with
          | .error e =>
              pure <| .error { code := -32030, message := "sphincs bundler unavailable", data := some (.str e) }
          | .ok bundlerUrl =>
              -- Primary query: receipt (authoritative).
              let receiptR ← Sphincs.Send.bundlerCall bundlerUrl
                  "eth_getUserOperationReceipt" (.arr #[.str userOpHash])
              -- Secondary query: byHash. Some bundlers populate this
              -- before the receipt; useful for fast-path inclusion.
              let byHashR ← Sphincs.Send.bundlerCall bundlerUrl
                  "eth_getUserOperationByHash" (.arr #[.str userOpHash])
              let receipt : Json := match receiptR with
                | .ok r => r
                | .error _ => .null
              let byHash : Json := match byHashR with
                | .ok r => r
                | .error _ => .null
              let isNull (j : Json) : Bool := match j with | .null => true | _ => false
              let included := ! (isNull receipt && isNull byHash)
              -- Bubble bundler error only if BOTH queries failed AND
              -- neither returned a parseable null.
              match receiptR, byHashR with
              | .error e1, .error e2 =>
                  pure <| .error { code := -32021, message := "bundler error",
                                   data := some (.str s!"receipt: {e1}; byHash: {e2}") }
              | _, _ =>
                  -- If included AND the caller passed a slot name, persist
                  -- the userOpHash → L1 txHash mapping to the journal so
                  -- the next `chain.history` call surfaces the L1 hash in
                  -- the UI. Idempotent: writing the same inclusion twice
                  -- is harmless (overlay logic just picks the latest).
                  let inclusionTxHash? : Option String :=
                    (getField "receipt" receipt >>= getField "transactionHash" |>.bind asString)
                    <|> (getField "transactionHash" byHash >>= asString)
                  let blockNumber? : Option String :=
                    (getField "receipt" receipt >>= getField "blockNumber" |>.bind asString)
                    <|> (getField "blockNumber" byHash >>= asString)
                  let success? : Option Bool := match getField "success" receipt with
                    | some (.bool b) => some b
                    | _ => none
                  match paramString req.params "name", inclusionTxHash? with
                  | .ok slotName, some itx =>
                      LeanCli.Daemon.TxJournal.appendInclusion
                        slotName userOpHash itx blockNumber? success?
                  | _, _ => pure ()
                  pure <| .ok <| .obj #[
                    ("userOpHash", .str userOpHash),
                    ("included", .bool included),
                    ("receipt", receipt),
                    ("info", byHash) ]
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.SphincsRpc
