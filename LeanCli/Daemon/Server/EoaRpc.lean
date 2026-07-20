import LeanCli.Daemon.Server.Core
import LeanCli.Daemon.Server.Helpers
import LeanCli.Daemon.Server.Endpoints
import LeanCli.Daemon.Server.Journal
import LeanCli.Daemon.Server.AddrGuard
import LeanCli.Crypto.Hex
import LeanCli.Daemon.State
import LeanCli.Encoding.Json
import LeanCli.Ethereum.Address
import LeanCli.Ethereum.Eip712
import LeanCli.Ethereum.TransferMax
import LeanCli.Ethereum.Tx
import LeanCli.Keystore.MasterKey
import LeanCli.Keystore.MasterPassphrase
import LeanCli.Keystore.Tpm2Runtime
import LeanCli.RPC.Outbound
import LeanCli.RPC.Server
import LeanCli.Wallet.EOA
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.Entropy
import LeanCli.Wallet.Mnemonic

/-!
# Daemon server: `eoa.*` RPC family

Externally-owned-account lifecycle, signing, send-path, and the
HSM-attestation key-confirmation flow. Twenty-three arms covering
the full EOA surface:

  Lifecycle: eoa.list / show / address / import / create / delete
             eoa.revealMnemonic / unlock / lock / derive
  Signing:   eoa.signDigest / signMessage / signTx / signTypedData
  Send:      eoa.maxSendable / send / dropNonce (replace-by-fee)
  Multi-account: eoa.account.list / findByAddress / add / rm
  HSM attestation: eoa.attestation.status / bootstrap / unlockAll
-/

namespace LeanCli.Daemon.Server.EoaRpc

open LeanCli.Encoding.Json
open LeanCli.Keystore.Tpm2Runtime
open LeanCli.RPC.Server
open LeanCli.Daemon.Server

/-- Handle every `eoa.*` JSON-RPC method. -/
def dispatch (cfg : Config) (state : LeanCli.Daemon.State.Shared)
    (notify : LeanCli.Keystore.Tpm2Runtime.Notifier)
    (req : Request) : IO (Except RpcError Json) := do
  match req.method with
  | "eoa.list" =>
      let names ← LeanCli.Wallet.EoaStore.list
      let records ← names.foldlM
        (fun acc name => do
          match ← LeanCli.Wallet.EoaStore.load name with
          | .ok record => pure (acc.push (← slotMetadataJson state record))
          | .error _ => pure acc)
        #[]
      pure (.ok (.arr records))
  | "eoa.show" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanCli.Wallet.EoaStore.load name with
          | .ok record => pure (.ok (← slotMetadataJson state record))
          | .error err =>
              pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
  | "eoa.address" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← LeanCli.Wallet.EoaStore.load name with
          | .ok record => pure (.ok (.str record.address))
          | .error err =>
              pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
  | "eoa.import" =>
      match ← saveMnemonicSlot state req.params none with
      | .error err => pure (.error err)
      | .ok (record, _) => pure (.ok (← importResultJson state record))
  | "eoa.create" =>
      try
        let wordCount := paramNatD req.params "wordCount" 12
        let mnemonic ← LeanCli.Wallet.Entropy.generateMnemonic wordCount
        match ← saveMnemonicSlot state req.params (some mnemonic) with
        | .error err => pure (.error err)
        | .ok (record, mnemonic?) => pure (.ok (← importResultJson state record mnemonic?))
      catch e =>
        pure <| .error { invalidParams with data := some (.str e.toString) }
  | "eoa.revealMnemonic" =>
      -- Why: passphrase-gated recovery of the BIP-39 words for slots
      -- created with mnemonic retention. Slots that predate the on-disk
      -- format change (`mnemonicWrap` absent) return -32030 with a
      -- pointer to the underlying constraint (BIP-39 seed → words is
      -- one-way). The plaintext is returned exactly once per call; we do
      -- not journal, log, or notify.
      match paramName req.params, paramString req.params "passphrase" with
      | .ok name, .ok passphrase =>
          match ← LeanCli.Wallet.EoaStore.load name with
          | .error err =>
              pure <| .error
                { code := -32010,
                  message := "EOA slot not found",
                  data := some (.str err) }
          | .ok record =>
              match ← LeanCli.Wallet.EoaStore.unwrapMnemonic record passphrase with
              | .error err =>
                  -- Distinguish "no stored mnemonic" from "wrong passphrase"
                  -- via prefix-match on the EoaStore error message — both
                  -- are surfaced with -32030 but with different data so the
                  -- TUI/CLI can render an appropriate message.
                  pure <| .error
                    { code := -32030,
                      message := "could not reveal mnemonic",
                      data := some (.str err) }
              | .ok phrase =>
                  let words := (phrase.splitOn " ").filter (· ≠ "")
                  let arr : Array Json := words.foldl
                    (fun acc w => acc.push (.str w)) (#[] : Array Json)
                  pure <| .ok <| .obj #[
                    ("name", .str name),
                    ("address", .str record.address),
                    ("derivationPath", .str record.derivationPath),
                    ("wordCount", .num (Int.ofNat words.length)),
                    ("mnemonic", .arr arr)
                  ]
      | _, _ => pure (.error invalidParams)
  | "eoa.unlock" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match ← LeanCli.Wallet.EoaStore.load name with
              | .error err =>
                  pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
              | .ok record =>
                  -- Master-KEK fast path: when the caller passes an empty
                  -- passphrase, the slot is enrolled under master (has a
                  -- `masterWrap` and is not `customPassphrase`), and the
                  -- master KEK is currently loaded, unwrap via master
                  -- instead of running the per-slot KDF. This lets the TUI
                  -- skip the passphrase prompt entirely for master-enrolled
                  -- slots without leaking which slots are enrolled (the
                  -- gating check happens entirely server-side; an empty
                  -- passphrase on a non-enrolled slot falls through to the
                  -- regular KDF path below, which fails with the usual
                  -- -32011). Additive: callers that supply a real
                  -- passphrase keep the prior behaviour byte-for-byte.
                  let masterFastPath? ← do
                    if passphrase.length == 0 && !record.customPassphrase then
                      match record.masterWrap with
                      | none => pure none
                      | some w =>
                          match ← LeanCli.Daemon.State.getMasterKek? state with
                          | none => pure none
                          | some slot =>
                              match ← LeanCli.Keystore.MasterPassphrase.unwrapSlot
                                  slot.kek record.name record.derivationPath record.address w with
                              | .error _ => pure none
                              | .ok seed => pure (some seed)
                    else pure none
                  match masterFastPath? with
                  | some seed =>
                      LeanCli.Daemon.State.unlock state {
                        name := record.name,
                        seed := seed,
                        address := record.address,
                        derivationPath := record.derivationPath,
                        unlockedAtMs := ← IO.monoMsNow,
                        ttlMs := 300000
                      }
                      pure (.ok (← slotMetadataJson state record))
                  | none =>
                  match ← LeanCli.Wallet.EoaStore.unlockSeedIO record passphrase with
                  | .error err =>
                      pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                  | .ok seed =>
                      LeanCli.Daemon.State.unlock state {
                        name := record.name,
                        seed := seed,
                        address := record.address,
                        derivationPath := record.derivationPath,
                        unlockedAtMs := ← IO.monoMsNow,
                        ttlMs := 300000
                      }
                      -- Lazy enrolment / self-heal: whenever the wallet
                      -- master is currently loaded and this slot is not
                      -- opted out, rewrap the seed under the current KEK.
                      -- Idempotent — covers three cases in one pass:
                      --   (a) first enrolment (`masterWrap.isNone`),
                      --   (b) stale wrap from a rotated/re-init'd master
                      --       (still `some _`, but ciphertext opens under
                      --       a KEK we no longer hold — surfaces as
                      --       `stale-wrap` from `wallet.unlock`),
                      --   (c) routine re-unlock under the same KEK
                      --       (semantically a no-op, costs one AEAD seal
                      --       + write — negligible).
                      -- Best-effort: rewrap errors are swallowed so the
                      -- per-slot unlock still succeeds.
                      if !record.customPassphrase then
                        match ← LeanCli.Daemon.State.getMasterKek? state with
                        | none => pure ()
                        | some slot =>
                            match ← LeanCli.Keystore.MasterPassphrase.wrapSlot
                                slot.kek record.name record.derivationPath record.address seed with
                            | .error _ => pure ()
                            | .ok wrap =>
                                let updated := { record with masterWrap := some wrap }
                                try LeanCli.Wallet.EoaStore.save updated
                                catch _ => pure ()
                      pure (.ok (← slotMetadataJson state record))
  | "eoa.lock" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          LeanCli.Daemon.State.lock state name
          pure (.ok (.obj #[("ok", .bool true)]))
  | "eoa.derive" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              let path := paramStringD req.params "path" slot.derivationPath
              match ← deriveAddressFromSeed slot.seed path with
              | .error err =>
                  pure <| .error { invalidParams with data := some (.str err) }
              | .ok address =>
                  pure <| .ok <| .obj #[
                    ("name", .str name),
                    ("path", .str path),
                    ("address", .str address)
                  ]
  | "eoa.signDigest" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "digest" req.params >>= asBytes with
              | none => pure (.error invalidParams)
              | some digest =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanCli.Wallet.EOA.signDigestIO privateKey digest with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok sig => pure (.ok (signatureJson sig))
  | "eoa.signMessage" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "message" req.params >>= asBytes with
              | none => pure (.error invalidParams)
              | some msg =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanCli.Wallet.EOA.signPersonalMessageIO msg privateKey with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok sig => pure (.ok (signatureJson sig))
  | "eoa.signTx" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match paramTx req.params with
              | .error err => pure (.error err)
              | .ok tx =>
                  match ← resolveSigningTarget name slot req.params with
                  | .error err => pure (.error err)
                  | .ok (path, _addr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      match ← LeanCli.Wallet.EOA.signEip1559IO tx privateKey with
                      | .error err =>
                          pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                      | .ok signed =>
                          pure <| .ok <| .obj #[
                            ("raw", .str (LeanCli.Crypto.Hex.encode signed.encode)),
                            ("signature", signatureJson signed.sig)
                          ]
  | "eoa.signTypedData" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match getField "typedData" req.params with
              | none => pure (.error invalidParams)
              | some typedData =>
                  match ← LeanCli.Ethereum.Eip712.computeDigestIO typedData with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok d =>
                      match ← resolveSigningTarget name slot req.params with
                      | .error err => pure (.error err)
                      | .ok (path, addr) =>
                      match ← derivePrivateKeyFromSeed slot.seed path with
                      | .error err =>
                          pure <| .error { invalidParams with data := some (.str err) }
                      | .ok privateKey =>
                          match ← LeanCli.Wallet.EOA.signDigestIO privateKey d.digest with
                          | .error err =>
                              pure <| .error { code := -32013, message := "EOA signing failed", data := some (.str err) }
                          | .ok sig =>
                              -- Why: pack r||s||v into a 65-byte 0x... compact signature
                              let r := LeanCli.Wallet.HDKey.Nat.toFixedBytes 32 sig.r
                              let s := LeanCli.Wallet.HDKey.Nat.toFixedBytes 32 sig.s
                              let v := ByteArray.empty.push sig.v
                              let compactSig := r ++ s ++ v
                              pure <| .ok <| .obj #[
                                ("signature", .str (LeanCli.Crypto.Hex.encode compactSig)),
                                ("digest", .str (LeanCli.Crypto.Hex.encode d.digest)),
                                ("domainSeparator", .str (LeanCli.Crypto.Hex.encode d.domainSeparator)),
                                ("messageHash", .str (LeanCli.Crypto.Hex.encode d.messageHash)),
                                ("primaryType", .str d.primaryType),
                                ("recoveredAddress", .str addr),
                                ("rsv", signatureJson sig)
                              ]
  | "eoa.maxSendable" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← loadRecord name with
          | .error err => pure (.error err)
          | .ok record =>
              let addressE : Except RpcError String :=
                match getField "account" req.params >>= asNat with
                | none => .ok record.address
                | some idx =>
                    match (recordAccounts record).find? (fun a => a.index = idx) with
                    | some account => .ok account.address
                    | none => .error {
                        code := -32014
                        message := s!"account index {idx} not found in slot"
                        data := none
                      }
              match addressE with
              | .error err => pure (.error err)
              | .ok address =>
                  let chainName? := getField "chain" req.params >>= asString
                  let cfgEff : Config :=
                    match chainName? with
                    | none => cfg
                    | some chainName =>
                        match endpointForChain cfg (some chainName) with
                        | .error _ => cfg
                        | .ok ep =>
                            let cid := (LeanCli.RPC.Outbound.chainNameToId chainName).getD cfg.chainId
                            { cfg with rpcEndpoint := ep, chainId := cid }
                  let via? ← verifiedReadVia state cfgEff.chainId cfgEff.rpcEndpoint
                  match ← LeanCli.RPC.Outbound.getBalance
                      cfgEff.policy cfgEff.rpcEndpoint address "latest" via? with
                  | .error err => pure <| .error {
                      code := -32020
                      message := "chain RPC failed while reading send balance"
                      data := some (.str err)
                    }
                  | .ok balanceJson =>
                      match jsonHexNat balanceJson with
                      | .error err => pure (.error err)
                      | .ok balance =>
                          match ← readCappedEip1559Fees cfgEff via? with
                          | .error err => pure (.error err)
                          | .ok fees =>
                              let gasLimit : Nat := 21_000
                              let reserve := gasLimit * fees.maxFeePerGas * 12 / 10
                              let amount :=
                                LeanCli.Ethereum.TransferMax.transferMaxAmountFromBalance
                                  balance reserve
                              pure <| .ok <| .obj #[
                                ("address", .str address),
                                ("balanceWei", .str (toString balance)),
                                ("reserveWei", .str (toString reserve)),
                                ("amountWei", .str (toString amount)),
                                ("gasLimit", .num (Int.ofNat gasLimit)),
                                ("maxFeePerGas", .str (toString fees.maxFeePerGas)),
                                ("chainId", .num (Int.ofNat cfgEff.chainId))
                              ]
  | "eoa.send" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match paramString req.params "to", paramNat req.params "value" with
              | .ok to, .ok value =>
                  match LeanCli.Ethereum.Address.fromHex to with
                  | none => pure (.error invalidParams)
                  | some toAddress =>
                      match txBytesFieldD req.params "data" with
                      | .error err => pure (.error err)
                      | .ok data =>
                          -- Pre-sign guard: refuse a zero-value, empty-
                          -- calldata tx. It carries no intent — to a
                          -- contract it reverts and only burns gas; the
                          -- calldata was dropped upstream. Native ETH sends
                          -- (value > 0) and contract funding are unaffected.
                          if isNoOpCall value data then
                            pure <| .error (noOpCallError to)
                          else
                          -- Pre-sign address-integrity gate: refuse to sign
                          -- when `to` or any address embedded in the calldata
                          -- is a near-miss to one of the daemon's own
                          -- addresses (the LLM-typo'd-spender footgun). The
                          -- caller overrides with acknowledgeAddressWarnings.
                          match ← LeanCli.Daemon.Server.AddrGuard.enforce req.params to
                              (LeanCli.Crypto.Hex.encode data) with
                          | .error e => pure (.error e)
                          | .ok () =>
                          match ← resolveSigningTarget name slot req.params with
                          | .error err => pure (.error err)
                          | .ok (path, fromAddr) =>
                          match ← derivePrivateKeyFromSeed slot.seed path with
                          | .error err =>
                              pure <| .error { invalidParams with data := some (.str err) }
                          | .ok privateKey =>
                              -- Why: re-target slot at the resolved account so nonce/from come from the right address.
                              let slot' := { slot with address := fromAddr, derivationPath := path }
                              -- Per-call chain override. Honors `params.chain`
                              -- when present: pick the per-chain endpoint
                              -- from cfg.chainEndpoints + the corresponding
                              -- chainId so the broadcast goes to the right
                              -- network. Without this, the chat path's
                              -- chainId=11155111 prompt broadcasted on the
                              -- daemon's default chain (mainnet) and tripped
                              -- the mainnet policy.
                              let chainName? := getField "chain" req.params >>= asString
                              let cfgEff : Config :=
                                match chainName? with
                                | none => cfg
                                | some name =>
                                    match endpointForChain cfg (some name) with
                                    | .error _ => cfg
                                    | .ok ep =>
                                        let cid := (LeanCli.RPC.Outbound.chainNameToId name).getD cfg.chainId
                                        { cfg with rpcEndpoint := ep, chainId := cid }
                              let via? ← verifiedReadVia state cfgEff.chainId cfgEff.rpcEndpoint
                              let r ← buildSignBroadcastTx cfgEff slot' privateKey to toAddress value data none (some notify) via?
                              -- Why: best-effort journal write; never fails the tx.
                              match r with
                              | .ok j =>
                                  let getStr (k : String) : String :=
                                    (getField k j >>= asString).getD ""
                                  let txHash := getStr "txHash"
                                  let nonceN := (parseHexQuantity (getStr "nonce")).getD 0
                                  let dataHex := LeanCli.Crypto.Hex.encode data
                                  let acc? := getField "account" req.params >>= asNat
                                  let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                                  let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                                  let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                                  if !txHash.isEmpty then
                                    journalRecord slot.name fromAddr to txHash dataHex "eoa.send"
                                      value nonceN cfgEff.chainId acc? status? block? gas?
                              | .error _ => pure ()
                              pure r
              | _, _ => pure (.error invalidParams)
  | "eoa.dropNonce" =>
      -- Replace a stuck pending nonce with a 0-value self-transfer at a
      -- forced priority tip. Frees the mempool slot so downstream nonces
      -- can land. Params:
      --   name            : EOA slot
      --   nonce           : the exact nonce to drop (no auto-pick — caller
      --                     must read it from `eth_getTransactionCount` first)
      --   account         : optional sub-account index (defaults to primary)
      --   priorityFeeGwei : optional tip in gwei (default 3 — enough to
      --                     outbid the typical Sepolia `eth_maxPriorityFeePerGas`
      --                     report of 0x15f900 ≈ 0.00144 gwei)
      --   chain           : optional chain override; honors `cfg.chainEndpoints`
      match paramName req.params, paramNat req.params "nonce" with
      | .ok name, .ok nonce =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match ← resolveSigningTarget name slot req.params with
              | .error err => pure (.error err)
              | .ok (path, fromAddr) =>
                  match ← derivePrivateKeyFromSeed slot.seed path with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok privateKey =>
                      let slot' := { slot with address := fromAddr, derivationPath := path }
                      let chainName? := getField "chain" req.params >>= asString
                      let cfgEff : Config :=
                        match chainName? with
                        | none => cfg
                        | some name =>
                            match endpointForChain cfg (some name) with
                            | .error _ => cfg
                            | .ok ep =>
                                let cid := (LeanCli.RPC.Outbound.chainNameToId name).getD cfg.chainId
                                { cfg with rpcEndpoint := ep, chainId := cid }
                      let tipGwei := paramNatD req.params "priorityFeeGwei" 3
                      let tipWei := tipGwei * 1_000_000_000
                      match LeanCli.Ethereum.Address.fromHex fromAddr with
                      | none => pure (.error invalidParams)
                      | some selfAddr =>
                          let via? ← verifiedReadVia state cfgEff.chainId cfgEff.rpcEndpoint
                          let r ← buildSignBroadcastTx cfgEff slot' privateKey fromAddr selfAddr 0
                            ByteArray.empty (some nonce) (some notify) via? (some tipWei)
                          match r with
                          | .ok j =>
                              let getStr (k : String) : String :=
                                (getField k j >>= asString).getD ""
                              let txHash := getStr "txHash"
                              let acc? := getField "account" req.params >>= asNat
                              let status? := if (getStr "status").isEmpty then none else some (getStr "status")
                              let block? := if (getStr "blockNumber").isEmpty then none else some (getStr "blockNumber")
                              let gas? := if (getStr "gasUsed").isEmpty then none else some (getStr "gasUsed")
                              if !txHash.isEmpty then
                                journalRecord slot.name fromAddr fromAddr txHash "" "eoa.dropNonce"
                                  0 nonce cfgEff.chainId acc? status? block? gas?
                          | .error _ => pure ()
                          pure r
      | _, _ => pure (.error invalidParams)
  | "eoa.delete" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match ← LeanCli.Wallet.EoaStore.load name with
              | .error err =>
                  pure <| .error { code := -32010, message := "EOA slot not found", data := some (.str err) }
              | .ok record =>
                  match ← LeanCli.Wallet.EoaStore.unlockSeedIO record passphrase with
                  | .error err =>
                      pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                  | .ok _ =>
                      LeanCli.Daemon.State.lock state name
                      LeanCli.Wallet.EoaStore.delete name
                      pure (.ok (.obj #[("ok", .bool true)]))
  | "eoa.account.list" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← loadRecord name with
          | .error err => pure (.error err)
          | .ok record =>
              let arr := (recordAccounts record).map accountToJson
              pure <| .ok <| .obj #[("accounts", .arr arr)]
  | "eoa.account.findByAddress" =>
      -- Scan every EOA slot's `accounts[]` looking for one whose
      -- `.address` matches the queried address (case-insensitive). When
      -- found, return `{ found: true, walletName, accountIndex,
      -- derivationPath }` — enough info for the sphincs commitRotation
      -- flow to point a slot at the new key without asking the user to
      -- remember which wallet they picked. Returns `{ found: false }`
      -- when the address isn't derivable from any local seed (e.g. a
      -- bare external key the user pasted).
      match paramString req.params "address" with
      | .error e => pure (.error e)
      | .ok rawAddr =>
          let target := rawAddr.toLower
          let names ← LeanCli.Wallet.EoaStore.list
          let rec scan : List String → IO (Option (String × Nat × String))
            | [] => pure none
            | n :: rest => do
                match ← LeanCli.Wallet.EoaStore.load n with
                | .error _ => scan rest
                | .ok r =>
                    let accts := recordAccounts r
                    match accts.find? (fun a => a.address.toLower = target) with
                    | some a => pure (some (n, a.index, a.path))
                    | none => scan rest
          match ← scan names with
          | none =>
              pure <| .ok <| .obj #[("found", .bool false), ("address", .str rawAddr)]
          | some (walletName, idx, path) =>
              pure <| .ok <| .obj #[
                ("found", .bool true),
                ("address", .str rawAddr),
                ("walletName", .str walletName),
                ("accountIndex", .num (Int.ofNat idx)),
                ("derivationPath", .str path) ]
  | "eoa.account.add" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match ← unlockedSlot state name with
          | .error err => pure (.error err)
          | .ok slot =>
              match ← loadRecord name with
              | .error err => pure (.error err)
              | .ok record =>
                  let existing := recordAccounts record
                  let idx := nextAccountIndex record
                  -- Why: caller may pass an explicit BIP-44 path; otherwise auto-pick m/44'/60'/0'/0/<idx>.
                  let pathE : Except String String :=
                    match getField "path" req.params >>= asString with
                    | some p => .ok p
                    | none => LeanCli.Wallet.Bip44.canonicalEthereumPath 0 0 idx
                  match pathE with
                  | .error err =>
                      pure <| .error { invalidParams with data := some (.str err) }
                  | .ok path =>
                      -- Reject duplicate path (would create two accounts at the same address).
                      if existing.any (fun a => a.path = path) then
                        pure <| .error { code := -32015, message := "account path already exists",
                                         data := some (.str s!"path {path} already present") }
                      else
                        match ← deriveAddressFromSeed slot.seed path with
                        | .error err =>
                            pure <| .error { invalidParams with data := some (.str err) }
                        | .ok address =>
                            let label : Option String := getField "label" req.params >>= asString
                            let newAcc : LeanCli.Wallet.EoaStore.Account :=
                              { index := idx, path := path, address := address, label := label }
                            let updated : LeanCli.Wallet.EoaStore.Record :=
                              { record with accounts := existing.push newAcc }
                            LeanCli.Wallet.EoaStore.save updated
                            pure <| .ok (accountToJson newAcc)
  | "eoa.account.rm" =>
      match paramName req.params with
      | .error err => pure (.error err)
      | .ok name =>
          match paramString req.params "passphrase" with
          | .error err => pure (.error err)
          | .ok passphrase =>
              match paramNat req.params "index" with
              | .error err => pure (.error err)
              | .ok idx =>
                  if idx = 0 then
                    pure <| .error { code := -32016,
                                     message := "cannot remove account index 0 (primary)",
                                     data := none }
                  else
                    match ← loadRecord name with
                    | .error err => pure (.error err)
                    | .ok record =>
                        match ← LeanCli.Wallet.EoaStore.unlockSeedIO record passphrase with
                        | .error err =>
                            pure <| .error { code := -32011, message := "EOA unlock failed", data := some (.str err) }
                        | .ok _ =>
                            let existing := recordAccounts record
                            match existing.find? (fun a => a.index = idx) with
                            | none =>
                                pure <| .error { code := -32014,
                                                 message := s!"account index {idx} not found in slot",
                                                 data := none }
                            | some removed =>
                                let kept := existing.filter (fun a => a.index != idx)
                                let updated : LeanCli.Wallet.EoaStore.Record :=
                                  { record with accounts := kept }
                                LeanCli.Wallet.EoaStore.save updated
                                pure <| .ok <| .obj #[
                                  ("ok", .bool true),
                                  ("removed", accountToJson removed)
                                ]
  | "eoa.attestation.status" =>
      let initialized ← LeanCli.Keystore.MasterKey.existsOnDisk
      let names ← LeanCli.Wallet.EoaStore.list
      let entries ← names.foldlM
        (fun acc name => do
          match ← LeanCli.Wallet.EoaStore.load name with
          | .ok r =>
              pure <| acc.push <| .obj #[
                ("name", .str r.name),
                ("attestationWrapped", .bool r.attestationWrap.isSome)
              ]
          | .error _ => pure acc)
        (#[] : Array Json)
      pure <| .ok <| .obj #[
        ("initialized", .bool initialized),
        ("slots", .arr entries)
      ]
  | "eoa.attestation.bootstrap" =>
      match getField "slots" req.params >>= asArray,
            paramString req.params "masterPin" with
      | none, _ => pure (.error invalidParams)
      | _, .error err => pure (.error err)
      | some slotsArr, .ok masterPin =>
          -- Why: get/derive the master key once. If absent, bootstrap a new
          -- one (PIN-bound seal). Both paths verify the PIN through the TPM.
          let masterRes ← do
            if ← LeanCli.Keystore.MasterKey.existsOnDisk then
              LeanCli.Keystore.MasterKey.unsealMaster masterPin notify
            else
              match ← LeanCli.Keystore.MasterKey.bootstrap masterPin notify with
              | .error err => pure (.error err)
              | .ok _ => LeanCli.Keystore.MasterKey.unsealMaster masterPin notify
          match masterRes with
          | .error err =>
              pure <| .error
                { code := -32020, message := "master attestation key unavailable",
                  data := some (.str err) }
          | .ok masterKey =>
              let mut results : Array Json := #[]
              for entry in slotsArr do
                let nameOpt := getField "name" entry >>= asString
                let passOpt := getField "passphrase" entry >>= asString
                match nameOpt, passOpt with
                | some name, some passphrase =>
                    match ← LeanCli.Wallet.EoaStore.load name with
                    | .error err =>
                        results := results.push <| .obj #[
                          ("name", .str name), ("ok", .bool false),
                          ("error", .str err)]
                    | .ok record =>
                        match ← LeanCli.Wallet.EoaStore.unlockSeedIO record passphrase with
                        | .error err =>
                            results := results.push <| .obj #[
                              ("name", .str name), ("ok", .bool false),
                              ("error", .str s!"unlock failed: {err}")]
                        | .ok seed =>
                            match ← LeanCli.Wallet.EoaStore.wrapWithMaster masterKey name seed with
                            | .error err =>
                                results := results.push <| .obj #[
                                  ("name", .str name), ("ok", .bool false),
                                  ("error", .str s!"wrap failed: {err}")]
                            | .ok wrap =>
                                let updated := { record with attestationWrap := some wrap }
                                LeanCli.Wallet.EoaStore.save updated
                                results := results.push <| .obj #[
                                  ("name", .str name), ("ok", .bool true)]
                | _, _ =>
                    results := results.push <| .obj #[
                      ("name", .str (nameOpt.getD "")), ("ok", .bool false),
                      ("error", .str "missing name or passphrase")]
              pure <| .ok <| .obj #[("results", .arr results)]
  | "eoa.attestation.unlockAll" =>
      match paramString req.params "masterPin" with
      | .error err => pure (.error err)
      | .ok masterPin =>
      match ← LeanCli.Keystore.MasterKey.unsealMaster masterPin notify with
      | .error err =>
          pure <| .error
            { code := -32020, message := "master attestation key unavailable",
              data := some (.str err) }
      | .ok masterKey =>
          let names ← LeanCli.Wallet.EoaStore.list
          let mut unlocked : Array Json := #[]
          let mut skipped : Array Json := #[]
          for name in names do
            match ← LeanCli.Wallet.EoaStore.load name with
            | .error err =>
                skipped := skipped.push <| .obj #[
                  ("name", .str name), ("reason", .str err)]
            | .ok record =>
                match record.attestationWrap with
                | none =>
                    skipped := skipped.push <| .obj #[
                      ("name", .str name), ("reason", .str "no-wrap")]
                | some wrap =>
                    match ← LeanCli.Wallet.EoaStore.unwrapWithMaster masterKey name wrap with
                    | .error err =>
                        skipped := skipped.push <| .obj #[
                          ("name", .str name), ("reason", .str err)]
                    | .ok seed =>
                        LeanCli.Daemon.State.unlock state {
                          name := record.name,
                          seed := seed,
                          address := record.address,
                          derivationPath := record.derivationPath,
                          unlockedAtMs := ← IO.monoMsNow,
                          ttlMs := 300000
                        }
                        unlocked := unlocked.push (.str name)
          pure <| .ok <| .obj #[
            ("unlocked", .arr unlocked),
            ("skipped", .arr skipped)
          ]
  | m =>
      pure <| .error { code := -32601, message := s!"method not found: {m}", data := none }

end LeanCli.Daemon.Server.EoaRpc
