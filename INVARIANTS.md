# Invariants

Living document. Each invariant is (a) stated informally, (b) sketched as a
Lean proposition, (c) tagged with its current proof status, and (d) linked
to the module where the proof lives (or will live).

Status legend:
- 📝 **stated** — proposition written, implementation/proof not started
- 🚧 **in-progress** — proposition formalized, proof partial
- ✅ **proved** — `theorem` closes without `sorry`
- 🔒 **axiomatized** — accepted as axiom pending replacement (e.g. FFI boundary)

---

## Category 0 — Verified wallet core

### 0.1 No key exfiltration
The verified core cannot output private-key material because key material is
not represented in the output type.

**Prop:** `containsPrivateKeyMaterial out = false`
**Status:** ✅ proved — `LeanKohaku/Invariants/Core.lean::no_key_exfiltration`

### 0.2 No raw signing oracle
The core signs only verified typed intents, never arbitrary bytes.

**Props:**
- `verifiedIntent s intent → intent.rawSigning = false`
- `signIntent s intent kind = ok signature → verifiedIntent s intent`

**Status:** ✅ proved — `LeanKohaku/Invariants/Core.lean`

### 0.3 No wrong-chain signing
Verified intents must use a supported chain, match the selected chain, and
match the observed RPC chain id.

**Props:**
- `verifiedIntent s intent → supportedChainId intent.chainId = true`
- `verifiedIntent s intent → intent.chainId = s.selectedChain`
- `verifiedIntent s intent → intent.rpcChainId = some intent.chainId`

**Status:** ✅ proved — `LeanKohaku/Invariants/Core.lean`

### 0.4 Approval and signer path correspondence
Signatures require user approval, and R1/EOA paths cannot silently substitute
for each other.

**Props:**
- `verifiedIntent s intent → intent.approved = true`
- `verifiedIntent s intent → intent.keyRef.kind = intent.signerKind`
- `SignEOA` outputs secp256k1 signatures
- `SignR1` outputs P-256 signatures

**Status:** ✅ proved — `LeanKohaku/Invariants/Core.lean`

### 0.5 R1 TPM policy and EIP-7702 guardrails
R1 signing requires an explicit satisfied TPM policy. EIP-7702-style intents
require explicit delegation approval and cannot use global chain id `0`.

**Props:**
- `verifiedIntent s intent → intent.signerKind = r1 → ∃ policy, intent.tpmPolicy = some policy ∧ policy.satisfied = true`
- `verifiedIntent s intent → intent.is7702 = true → intent.delegateApproved = true ∧ intent.chainId ≠ 0`

**Status:** ✅ proved — `LeanKohaku/Invariants/Core.lean`

---

## Category 1 — Amount arithmetic

### 1.1 Checked subtraction never underflows
A balance debit of `b` from `a` either produces a total `r` with `r + b = a`,
or explicitly fails with `none`. `Nat.sub` silent-clamps to zero, which would
be a catastrophic bug for wallet accounting.

**Prop:** `∀ a b r, subChecked a b = some r → r + b = a`
**Status:** ✅ proved — `LeanKohaku/Invariants/Amount.lean::subChecked_preserves_total`

### 1.2 Sum of outputs ≤ available balance
For any multi-output send, the wallet refuses to sign unless the sum of
outgoing amounts plus fees is ≤ the sending account's balance. The abstract
model is in `LeanKohaku/Invariants/Wallet.lean`: `State`, `Send`, `apply`.

**Props:**
- `apply_some_affordable` — `apply σ s = some σ' → s.affordable σ`
- `apply_sender_debited` — `apply σ s = some σ' → σ'.balance s.sender + s.total = σ.balance s.sender`
- `apply_non_sender_balance` — non-sender accounts grow by exactly the sum of outputs addressed to them.

**Status:** ✅ proved — `LeanKohaku/Invariants/Wallet.lean`

---

## Category 2 — Transaction well-formedness

### 2.1 EIP-1559 fee relation
`maxPriorityFeePerGas ≤ maxFeePerGas` — otherwise the tx is invalid per
EIP-1559 and will be rejected by every mainnet node.

**Prop:** part of `wellFormed`
**Status:** ✅ defined (no theorem needed — it's the definition)
**Location:** `LeanKohaku/Invariants/TxWellFormed.lean`

### 2.2 Intrinsic gas lower bound
`gasLimit ≥ 21_000` for any plain value transfer; higher lower bounds apply
when `data` is non-empty (4 gas per zero byte, 16 per non-zero).

**Prop:** `wellFormed` currently encodes only the bare-transfer bound;
extend to calldata-aware bound next.
**Status:** 🚧 partial

### 2.3 Chain-ID match
The signed chain-id must match the configured chain, to prevent cross-chain
replay.

**Prop:** part of `wellFormed`
**Status:** ✅ defined

---

## Category 3 — Signing

### 3.1 Signed-amount integrity
The `value` field the user confirmed is bit-identical to the `value` in the
broadcast tx. No LLM-driven rewrite, no silent rounding.

**Prop:** `∀ userIntent tx, broadcast tx → confirmed userIntent →
          userIntent.value = tx.value`
**Status:** 📝 stated — requires threading a `UserIntent` type through the CLI

### 3.2 Deterministic nonce use
Once a nonce `k` has been signed for account `a`, the wallet never signs
another tx with nonce `≤ k` for `a`.

**Prop:** `∀ l a n, validNext l a n → n > (l a).getD 0`
**Status:** 📝 stated — `LeanKohaku/Invariants/Nonce.lean`

### 3.3 R1 signature verifiability
For every operation signed by the local keystore, the account logic can
verify the P-256/R1 signature against the stored public key through the
Ethereum P256VERIFY precompile model.

**Prop:** TBD (depends on account validation model + P256 precompile call encoding)
**Status:** 📝 stated

---

## Category 4 — Encoding

### 4.1 RLP roundtrip
Every RLP item decodes back to itself after encoding.

**Prop:** TBD once the RLP module is reintroduced
**Status:** 🚧 in-progress — structural lemmas (`natBytes_zero`, `encodeNat_zero`,
`encodeEmptyList_eq`, `singleton_size`, `concat_nil`) proved in
`LeanKohaku/Invariants/Encoding.lean`. Full round-trip blocked on a
non-`partial` decoder.

### 4.2 Hex roundtrip
`decode ∘ encode = some` on byte arrays.

**Prop:** `∀ b : ByteArray, Hex.decode (Hex.encode b) = some b`
**Status:** 🚧 in-progress — nibble-level round-trip and the digit/char tables
are proved in `LeanKohaku/Invariants/Encoding.lean` (`hexDigit_*`,
`nibbleToChar_*`, `nibble_round_trip_*`). Byte-level lift pending.

### 4.4 JSON destructors agree with constructors
The `as*` destructors used by the daemon dispatcher behave as left
inverses of the matching constructors and reject mismatched shapes
(e.g. `asString .null = none`).

**Props:**
- `asString (.str s) = some s`
- `asArray (.arr xs) = some xs`
- `asNat (.num (Int.ofNat n)) = some n`
- `asNat (.num (-1)) = none`
- `asString .null = none`

**Status:** ✅ proved — `LeanKohaku/Invariants/Encoding.lean`

### 4.3 Account policies are supported-chain/local-only
The CLI supports regular BIP-39 k1 EOAs and local R1 smart accounts. Both
accepted policies are local custody only and limited to explicitly supported
Ethereum chains: mainnet for production and Sepolia for development.

**Props:**
- `accepted p = true → supportedChainId p.chainId = true`
- `accepted p = true → p.localOnly = true`
- `accepted defaultEoaK1 = true`
- `accepted defaultR1Smart = true`
- `accepted sepoliaEoaK1 = true`
- `accepted sepoliaR1Smart = true`

**Status:** ✅ proved — `LeanKohaku/Invariants/Account.lean`

---

## Category 5 — Railgun / privacy notes (later)

### 5.1 No double-spend
A Railgun note's nullifier, once observed in a proven spend, cannot appear
in another valid spend.

**Prop:** TBD — requires modeling the Railgun note tree and nullifier set.
**Status:** 📝 stated (future)

### 5.2 Shield conservation
Sum of values shielded in = sum of notes created + fee.

**Prop:** TBD
**Status:** 📝 stated (future)

### 5.7 Bridge methods are policy-classified
Every method exposed by the kohaku-bridge sidecar is mapped to a
`NetworkPolicy.Purpose`: broadcast methods to `shieldedBroadcast`,
local introspection (`ping`, `version`, `listProtocols`) to
`daemonControl`, and everything else to `shieldedRead`. `strictDaemonPolicy`
denies every shielded purpose; `torDaemonPolicy` permits shielded purposes
only over Tor to a configured node.

**Props (proved):**
- `methodPurpose "shielded.broadcast" = .shieldedBroadcast`
- `methodPurpose "shielded.signAndBroadcast" = .shieldedBroadcast`
- `methodPurpose "ping" = .daemonControl`
- `∀ peer transport, strictDaemonPolicy { shieldedRead, … } = false`
- `∀ peer transport, strictDaemonPolicy { shieldedBroadcast, … } = false`
- `torDaemonPolicy { shieldedRead, … } = true → peer = configuredNode ∧ transport = tor`
- `torDaemonPolicy { shieldedBroadcast, … } = true → peer = configuredNode ∧ transport = tor`

**Status:** 🚧 in-progress — classification + strict/tor lemmas proved in
`LeanKohaku/Invariants/Bridge.lean`. Runtime gate that *forces* every
`Bridge.call` through `policyAllows` still pending.

### 5.8 Bridge responses cannot be confused
The JSON envelope `responseToJson` carries an `ok : Bool` that is `true`
exactly for `Response.ok` and `false` for both `Response.err` and
`Response.crash`. The daemon cannot mistake a sidecar crash for a
successful proof.

**Props (proved):**
- `okField (responseToJson (.ok j))    = some true`
- `okField (responseToJson (.err _ _ _)) = some false`
- `okField (responseToJson (.crash _ _)) = some false`

**Status:** ✅ proved — `LeanKohaku/Invariants/Bridge.lean`

### 5.3 Bridge cannot return spending-key material
`Bridge.Response` is an inductive type with no field of type
`ByteArray` named for spending or viewing keys. Plaintext key material
therefore cannot cross the Lean boundary, regardless of what the Node
sidecar prints.

**Status:** 🔒 by-construction — checked by inspection of
`LeanKohaku/Privacy/Bridge.lean`. Will be machine-checked once a
`ContainsKeyMaterial` predicate is added analogously to invariant 0.1.

### 5.9 CLI wallet actions preflight only through local daemon
`balance` and `send` are validated locally, then classified as local daemon
control over loopback. They do not directly contact nodes or third-party
services.

**Props:**
- `daemonRequest action = { peer := localDaemon, purpose := daemonControl, transport := loopback }`
- `preflight policy action = true → action.valid = true`
- `preflight strictCliPolicy action = true → strictCliPolicy (daemonRequest action) = true`
- `parseSend to amount = some action → ∃ n, action = send to n ∧ n > 0`

**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean`

### 5.10 Daemon action plans stay inside modeled provider operations
The daemon maps `balance` to `eth_getBalance` and `send` to
`eth_sendRawTransaction`. Strict plans use the local node over loopback;
Tor plans use configured-node Tor transport.

**Props:**
- `providerOperation (balance address) = eth_getBalance`
- `providerOperation (send to amountWei) = eth_sendRawTransaction`
- `strictPermitted req = true`
- `torPermitted req = true`

**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean`

### 5.11 Endpoint hygiene rejects credentialed and third-party endpoints
Endpoint policy is separate from request policy so hosted APIs and hidden
API-key dependencies can be rejected before transport code exists.

**Props:**
- `acceptedStrict ep = true → ep.credentialed = false`
- `acceptedTor ep = true → ep.credentialed = false`
- `acceptedStrict ep = true → ep.kind = local ∧ ep.transport = loopback`
- `acceptedTor ep = true → ep.kind ≠ thirdParty`

**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean`

---

## Category 6 — Network privacy

### 6.1 CLI only talks to the local daemon
The CLI must not contact Ethereum nodes or external services directly. It
may only use local daemon control over loopback.

**Prop:** `strictCliPolicy req = true → req.peer = localDaemon ∧ req.purpose = daemonControl ∧ req.transport = loopback`
**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean::strictCli_onlyLocalDaemon`

### 6.2 Daemon policies never allow third-party API peers
The daemon is the only component allowed to perform node I/O, but strict
and Tor policies reject third-party API peers.

**Props:**
- `strictDaemonPolicy req = true → req.peer ≠ thirdPartyApi`
- `torDaemonPolicy req = true → req.peer ≠ thirdPartyApi`

**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean`

### 6.3 Strict mode denies configured-node access
Under strict policy, configured-node access is denied entirely. Remote
configured-node access requires the explicit Tor policy.

**Props:**
- `strictDaemonPolicy req = true → req.peer ≠ configuredNode`
- `permitted strictDaemonPolicy cfg op = true → cfg.backend ≠ configuredNode`

**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean`

### 6.4 Third-party purposes are denied
Analytics, price quotes, metadata/indexer lookup, fiat/onramp calls, crash
reports, and discovery are not wallet-network purposes.

**Prop:** `thirdPartyPurpose req.purpose = true → strictDaemonPolicy req = false`
**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean::deniedThirdPartyPurposesStrict`

### 6.5 Tor configured-node access is Tor-only
When configured-node access is enabled via Tor policy, it must use Tor
transport.

**Props:**
- `torDaemonPolicy req = true → req.peer = configuredNode → req.transport = tor`
- `permitted torDaemonPolicy cfg op = true → cfg.backend = configuredNode → cfg.transport = tor`

**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean`

### 6.6 Per-chain RPC URL precedence
Persisted `daemon.json` entries always win over env-supplied URLs; the
namespaced env form `LEANKOHAKU_RPC_URL_<UPPER>` always wins over the generic
`<UPPER>_RPC_URL`. This rules out a stale env value silently overriding
explicit user config or the legacy generic form shadowing the leanKohaku-
namespaced one.

**Props:**
- `pickChainUrl (some p) ns gen = some (p, .persisted)`
- `pickChainUrl none (some ns) (some gen) = some (ns, .namespaced)`
- `pickChainUrl none none (some gen) = some (gen, .generic)`
- `pickChainUrl none none none = none`

**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean::pickChainUrl_*`

---

## Category 7 — Provider policy

### 7.1 Provider non-broadcast methods are reads
The provider surface classifies read-only methods separately from
`eth_sendRawTransaction`, so transport code can deny broad remote querying
and permit only strictly necessary broadcasts.

**Prop:** `m ≠ sendRawTransaction → m.purpose = nodeRead`
**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean::nonBroadcastMethodsAreReads`

### 7.2 Strict mode denies configured providers
Strict mode keeps reads and broadcasts local. Configured-node access is
available only through the explicit Tor policy.

**Prop:** `permitted strictDaemonPolicy cfg op = true → cfg.backend ≠ configuredNode`
**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean::strictConfiguredProviderDenied`

### 7.3 Tor provider access is transport-scoped
When the provider model is evaluated under Tor daemon policy, any allowed
configured-node access must be classified as Tor transport.

**Prop:** `permitted torDaemonPolicy cfg op = true → cfg.backend = configuredNode → cfg.transport = tor`
**Status:** ✅ proved — `LeanKohaku/Invariants/Network.lean::torConfiguredProviderOnlyTor`

---

## Category 8 — Local keystore

### 8.1 Accepted keystore requests never export secrets
The wallet-facing keystore API is local-only and does not expose raw
private keys, seed material, or import/export flows in accepted operation.

**Prop:** `policyAccepts req = true → req.op ≠ exportSecret ∧ req.op ≠ importSecret`
**Status:** ✅ proved — `LeanKohaku/Invariants/Keystore.lean::acceptedNeverExportsSecrets`

### 8.2 Accepted keystore requests are local-only
The keystore model is not an online service. Accepted requests must use
local-only platform or local hardware custody.

**Prop:** `policyAccepts req = true → req.policy.locality = localOnly ∧ req.policy.backend.localOnly = true`
**Status:** ✅ proved — `LeanKohaku/Invariants/Keystore.lean::acceptedRequiresLocalOnly`

### 8.3 Accepted signing requires user authorization
Signing requires a hardware-backed backend and user authorization, modeled
as biometrics or explicit user presence.

**Prop:** `policyAccepts { op := signDigest, policy := policy } = true → policy.requiredAuth = biometric ∨ policy.requiredAuth = userPresence`
**Status:** ✅ proved — `LeanKohaku/Invariants/Keystore.lean::acceptedSigningRequiresUserAuth`

### 8.4 Apple Secure Enclave accepts local Ethereum R1 signing policy
Native Apple Secure Enclave is modeled for P-256/R1. Ethereum mainnet
support uses account logic plus P256VERIFY rather than an EOA secp256k1
key.

**Prop:** `policyAccepts { op := signDigest, policy := appleEthereumR1Policy } = true`
**Status:** ✅ proved — `LeanKohaku/Invariants/Keystore.lean::appleSecureEnclaveAcceptsEthereumR1Signing`

### 8.5 Linux HP/Lenovo profiles prefer TPM2 signing
Common HP business notebook/workstation and Lenovo ThinkPad/ThinkCentre
profiles select TPM2 as the first hardware-backed local P-256/R1 signing
backend. FIDO2 is modeled as the fallback for systems without TPM2, while
the Linux kernel keyring is handle storage only.

**Props:**
- `selectSigningPolicy hpBusinessNotebook = some linuxTpm2Policy`
- `selectSigningPolicy hpMobileWorkstation = some linuxTpm2Policy`
- `selectSigningPolicy lenovoThinkPad = some linuxTpm2Policy`
- `selectSigningPolicy lenovoThinkCentre = some linuxTpm2Policy`
- `selectSigningPolicy genericFido2Only = some linuxFido2Policy`
- `selectHandleStore hpBusinessNotebook = some linuxKernelKeyring`

**Status:** ✅ proved — `LeanKohaku/Invariants/Keystore.lean`

---

## Category 9 — Ethereum EIP-7951 P256VERIFY

### 9.1 EIP-7951 P256VERIFY constants and chain ids
The wallet targets Ethereum L1 mainnet for production and Sepolia for
development. It models the EIP-7951 R1 verification precompile at address
`0x100`, input length `160`, success output length `32`, failure output
length `0`, and gas cost `6900`.

**Prop:** `mainnetChainId = 1 ∧ sepoliaChainId = 11155111 ∧ address = 0x100 ∧ inputLength = 160 ∧ gasCost = 6900`
**Status:** ✅ proved — `LeanKohaku/Invariants/Mainnet.lean`

---

## Category 10 — R1 account contract

### 10.1 R1 account accepts only supported-chain operations
The account model rejects any operation whose chain id is not explicitly
supported by the wallet policy.

**Prop:** `apply st op verify = some st' → supportedChainId op.chainId = true`
**Status:** ✅ proved — `LeanKohaku/Invariants/R1Account.lean::applySomeSupportedChainOnly`

### 10.2 R1 account nonce advances only after EIP-7951 verification
Accepted operations must consume the current nonce, use valid EIP-7951
precompile input, and pass the verifier hook before nonce advances.

**Props:**
- `apply st op verify = some st' → op.nonce = st.nonce`
- `apply st op verify = some st' → validInput (toPrecompileInput st.key op)`
- `apply st op verify = some st' → verify (toPrecompileInput st.key op) = true`
- `apply st op verify = some st' → st'.nonce = st.nonce + 1`

**Status:** ✅ proved — `LeanKohaku/Invariants/R1Account.lean`

---

## Category 12 — Sphincs hybrid account contract

The on-chain `SphincsAccount.sol` contract is a hybrid ECDSA + stateless
SPHINCS+ ERC-4337 account with rotatable key material. Every UserOp is
gated by **both** ECDSA recovery to a stored `owner` AND a stateless
SPHINCS+ verifier keyed by stored `(pkSeed, pkRoot)`. Rotation goes
through dedicated self-call paths `rotateKeys(bytes32,bytes32)` and
`rotateOwner(address)`. The Lean abstract model lives in
`LeanKohaku/Contract/SphincsAccount.lean`.

The verifier contract address is part of the deployed account's immutable
configuration, so SPHINCS+ parameter-set selection (e.g. JARDIN SPX vs
SLH-DSA-SHA2-128-24) lives outside this abstract model: the user's local
signer must produce signatures that match the parameter set the deployed
verifier accepts.

### 12.1 Sphincs account accepts only supported-chain operations
The account model rejects any operation whose chain id is not explicitly
supported by the wallet policy.

**Prop:** `apply st op verify = some st' → supportedChainId op.chainId = true`
**Status:** ✅ proved — `LeanKohaku/Invariants/SphincsAccount.lean::applySomeSupportedChainOnly`

### 12.2 Sphincs account nonce monotonicity
Accepted operations consume the current nonce and advance it by one.

**Props:**
- `apply st op verify = some st' → op.nonce = st.nonce`
- `apply st op verify = some st' → st'.nonce = st.nonce + 1`

**Status:** ✅ proved — `applySomeConsumesCurrentNonce`,
`applySomeIncrementsNonce`

### 12.3 Sphincs account hybrid signature gate
Every accepted operation passed both the ECDSA recovery check (recovers
to the **pre-state** `owner`) and the stateless SPHINCS+ verifier
(against the **pre-state** `(pkSeed, pkRoot)`). A break of either
primitive alone is insufficient to forge a UserOp.

**Props:**
- `apply st op verify = some st' →
     verify.ecdsaRecover op.digest op.ecdsaSig = some st.key.owner`
- `apply st op verify = some st' →
     verify.sphincsVerify st.key.pkSeed st.key.pkRoot op.digest op.sphincsSig = true`

**Status:** ✅ proved — `applySomeEcdsaRecoversToOwner`,
`applySomePqVerifies`

### 12.4 Sphincs account rotation isolation
Each payload preserves exactly the half of the key material it does not
rotate.

**Props:**
- `apply st op verify = some st' → op.payload = .regular →
     st'.key = st.key`
- `apply st op verify = some st' → op.payload = .rotateKeys s r →
     st'.key.owner = st.key.owner`
- `apply st op verify = some st' → op.payload = .rotateOwner o →
     st'.key.pkSeed = st.key.pkSeed ∧ st'.key.pkRoot = st.key.pkRoot`

**Status:** ✅ proved — `applyRegularKeysUnchanged`,
`applyRotateKeysPreservesOwner`, `applyRotateOwnerPreservesKeys`

### 12.5 Sphincs account owner rotation safety
The `rotateOwner(0x0…0)` call is rejected by the contract (`require(newOwner != address(0))`).

**Prop:** `op.payload = .rotateOwner addressZero → apply st op verify = none`
**Status:** ✅ proved — `LeanKohaku/Invariants/SphincsAccount.lean::applyRotateOwnerNonZero`

### 12.6 Sphincs PQ key supersession
After a successful `rotateKeys` to `(s', r')`, every subsequent accepted
op must SPHINCS+-verify against `(s', r')`. Equivalently: an oracle that
only accepts the previous `(pkSeed, pkRoot)` cannot accept any op after
the rotation. This is the load-bearing PQ-recovery property: `rotateKeys`
genuinely supersedes a compromised SPHINCS+ key.

**Prop:** `apply st op1 verify = some st' →
           op1.payload = .rotateKeys s' r' →
           apply st' op2 verify = some st'' →
             verify.sphincsVerify s' r' op2.digest op2.sphincsSig = true`
**Status:** ✅ proved — `LeanKohaku/Invariants/SphincsAccount.lean::applyRotateKeysSupersedesOldPq`

### 12.7 Sphincs owner rotation supersession
Symmetric to 12.6 for `rotateOwner`: after a successful owner rotation,
every subsequent accepted op must ECDSA-recover to the new owner. An
attacker holding only the previous owner's ECDSA key cannot produce a
further accepted op.

**Prop:** `apply st op1 verify = some st' →
           op1.payload = .rotateOwner newOwner →
           apply st' op2 verify = some st'' →
             verify.ecdsaRecover op2.digest op2.ecdsaSig = some newOwner`
**Status:** ✅ proved — `LeanKohaku/Invariants/SphincsAccount.lean::applyRotateOwnerSupersedesOldOwner`

---

## Category 11 — Swap (Uniswap V3)

### 11.1 Slippage zero is identity
A 0-bps slippage tolerance applied to a quoted output amount must leave
the amount untouched. Rules out off-by-one rounding bugs in the slippage
helper used by `swap exec` when assembling `amountOutMinimum`.

**Prop:** `applySlippageBps amountOut 0 = amountOut`
**Status:** ✅ proved — `LeanKohaku/Invariants/Swap.lean::slippageZeroIsIdentity`

### 11.2 swap.balances candidate set is chain-correct
The token list `swap.balances` fans out to (per `balancesCandidates`)
contains only `(token, addr)` pairs where `addressOn token chain = some
addr`. Rules out using a mainnet address on sepolia (or vice-versa) when
querying `balanceOf` — a silent fall-through here would produce a
balance for a non-deployed contract and mis-render in the TUI.

**Prop:** `(t, addr) ∈ balancesCandidates chain → addressOn t chain = some addr`
**Status:** ✅ proved — `LeanKohaku/Invariants/Swap.lean::balancesCandidates_addressOn_some`

---

## Category 13 — Cryptographic assumptions (axiomatized)

The wallet's end-to-end security cannot be discharged by Lean proofs alone —
hash collision-resistance, signature unforgeability, AEAD authenticity, and
KDF/PRF properties are standard cryptographic assumptions, not theorems.
Every entry below is 🔒 axiomatized: it lives behind an `opaque` in
`LeanKohaku/Crypto/Hacl.lean` (bound to HACL\*/RustCrypto), behind
`LeanKohaku/Crypto/Secp256k1Native.lean`, or as an oracle parameter in an
account contract model. None can be flipped to ✅; they exist to be cited
by the load-bearing proofs above.

### 13.1 Keccak-256 collision and preimage resistance
`Crypto/Hacl.lean::keccak256Ethereum` (Ethereum delimiter `0x01`). Load-bearing
for EIP-1559 signing (`Wallet/EOA.lean`), address derivation
(`Wallet/Address.lean`), EIP-712 (`Ethereum/Eip712.lean`), ENS namehash
(`Ethereum/Ens.lean`), 4-byte selectors (`Swap/UniV3.lean`), and ERC-4337
`userOpHash` (`Sphincs/UserOp.lean`).

**Assumption:** collision/preimage/second-preimage-resistance at 128-bit
security. A break invalidates every signing flow and every
domain-separation tag.

### 13.2 SHA-256 collision and preimage resistance
`Crypto/Hacl.lean::sha256`. Load-bearing for the BIP-39 mnemonic checksum
(`Wallet/Mnemonic.lean`) and the BIP-32 HASH160 fingerprint input
(`Wallet/HDKey.lean`).

**Assumption:** collision and preimage resistance at 128-bit security.

### 13.3 RIPEMD-160 second-preimage resistance for HASH160
`Crypto/Hacl.lean::ripemd160` (separate RustCrypto helper; pinned HACL does
not expose RIPEMD-160). Used only for BIP-32 HASH160 child-key fingerprints
(`Wallet/HDKey.lean`), never for Ethereum addresses.

**Assumption:** second-preimage-resistance sufficient for HD-wallet
fingerprint disambiguation. Full collision-resistance is not required —
fingerprints are advisory.

### 13.4 HMAC-SHA-512 is a PRF
`Crypto/Hacl.lean::hmacSha512`. Load-bearing for BIP-32 child-key
derivation (`Wallet/HDKey.lean`).

**Assumption:** HMAC-SHA-512 is a secure pseudo-random function under the
standard NMAC/dual-PRF assumptions. A break leaks the chain code and
breaks BIP-32 path independence.

### 13.5 PBKDF2-HMAC-SHA-512 is a slow KDF
`Crypto/Hacl.lean::pbkdf2HmacSha512`. Load-bearing for BIP-39 seed
derivation (`Wallet/Mnemonic.lean`) and at-rest keystore wrapping
(`Wallet/EoaStore.lean`).

**Assumption:** PBKDF2 with the configured iteration count provides the
documented work factor against passphrase brute force.

### 13.6 ChaCha20-Poly1305 is IND-CCA / INT-CTXT secure
`Crypto/Hacl.lean::{chacha20Poly1305Seal,chacha20Poly1305Open}`.
Load-bearing for at-rest keystore encryption (`Wallet/EoaStore.lean`).

**Assumption:** ChaCha20-Poly1305 with a fresh 96-bit nonce per
encryption is IND-CCA secure and provides ciphertext integrity.
Nonce-uniqueness is a wallet-side obligation; nonce reuse on the same
key voids both guarantees.

### 13.7 secp256k1 ECDSA is EUF-CMA
`Crypto/Secp256k1Native.lean::{signIO,recoverIO,verifyIO,pubkeyIO}`, bound
to libsecp256k1. The pure spec module `Crypto/Secp256k1.lean` is not used
at runtime. Load-bearing for EOA signing (`Wallet/EOA.lean`) and the
ECDSA half of the Sphincs hybrid gate (12.3, 12.7).

**Assumption:** existential unforgeability under chosen-message attack of
ECDSA over secp256k1 with low-S signatures, and faithful behavior of
libsecp256k1.

### 13.8 P-256 / EIP-7951 P256VERIFY is EUF-CMA
Modeled by the `verify : PrecompileInput → Bool` parameter of
`Invariants/R1Account.lean::apply`; on-chain by the EIP-7951 precompile
at address `0x100`. Hardware backends are modeled in Category 8. The 9.1
and 10.x proofs are vacuous unless the oracle reflects ECDSA-P-256
EUF-CMA.

**Assumption:** existential unforgeability under chosen-message attack of
ECDSA over NIST P-256, and faithful implementation by the deployed
EIP-7951 precompile.

### 13.9 SPHINCS+ is EUF-CMA (post-quantum)
Modeled by `Contract/SphincsAccount.lean::VerifyOracle.sphincsVerify`;
runtime signing goes through the SPHINCS+ sidecars under `bridge/`. The
12.3 and 12.6 proofs are vacuous unless the oracle reflects SPHINCS+
EUF-CMA, in particular preimage-resistance of the underlying tweakable
hash family.

**Assumption:** existential unforgeability under chosen-message attack of
the configured SPHINCS+ parameter set against quantum and classical
adversaries, and faithful implementation by both the local sidecar and
the on-chain verifier contract.

### 13.10 Native helper integrity
Every primitive in this category is reached through a one-shot
subprocess (`runHexHelper` in `Crypto/Hacl.lean`, mirrored in
`Crypto/Secp256k1Native.lean`). The Lean side does not link the
implementations; it spawns a binary by basename (see
`Crypto/Hacl.lean:42-49` and `Crypto/Secp256k1Native.lean:14-17`) and
parses hex from stdout.

**Assumption:** the helper binaries on `$PATH` faithfully implement the
named primitive and have not been substituted by an attacker. A
compromised helper defeats every higher-level invariant.

---

## How we extend this file

1. New invariant idea arises during implementation or review.
2. Add it here with a stub Lean proposition (no proof yet).
3. Open a module under `LeanKohaku/Invariants/` if one doesn't exist.
4. Write the proposition formally; mark 🚧 once `theorem … := by sorry` compiles.
5. Replace `sorry` with a real proof; flip to ✅.
