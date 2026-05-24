# web3-security — operational checklist

## Threat model in one sentence

The user's signing key is the asset; everything else — RPC providers,
sidecars, browser extensions, this LLM, even chain reads — is
untrusted and must be re-validated before the signature is produced.

## Key separation

| Role | Where it lives | Used for |
|---|---|---|
| EOA secp256k1 seed | BIP-39 mnemonic, encrypted at rest | Owner of legacy + EIP-1559 EOAs |
| R1 P-256 private key | TPM / Secure Enclave (never extractable) | Local signer for R1 smart accounts |
| Master KEK | Daemon process memory, ciphertext at rest | Decrypts the seed cache; never leaves the daemon |
| Master passphrase | Never persisted in cleartext | Derives a key (PBKDF2-HMAC-SHA-512) that wraps the KEK |

The master passphrase, the EOA seed, and the R1 device key are
cryptographically independent. A compromise of the passphrase does
not yield the R1 key (different cryptosystem) and vice versa. See
invariants 8.6 and 8.7.

## Signature semantics — what the user is actually agreeing to

* **Raw ECDSA over an arbitrary 32-byte digest** — never. The wallet
  has no raw-signing oracle (invariant 0.2).
* **EIP-191 personal_sign** (`\x19Ethereum Signed Message:\n…`) — a
  literal message. Cannot authorise a transaction by itself.
* **EIP-712 typed-data sign** — a structured payload bound to a
  domain separator. The user must see the full
  decoded structure before signing; do NOT show only the digest.
  Walk it with `decode_eip712`.
* **EIP-1559 transaction signing** — the verified core enforces
  chainId match, monotonic nonce, fee relation
  (`maxPriorityFeePerGas ≤ maxFeePerGas`), and minimum gas.

## Fee / gas verification

* Reject `maxPriorityFeePerGas > maxFeePerGas` (invariant 2.1).
* Reject `gasLimit < 21_000` for any plain transfer (invariant 2.2,
  partial).
* Treat `eth_estimateGas` and `debug_traceCall` results as untrusted
  hints; surface them to the user and let them confirm.
* Wallet refuses txs whose total cost (sum of outputs + fees) exceeds
  the sender's balance (invariant 1.2).

## EIP-712 risks the agent must surface

* **Open-ended `permit`** — A `permit(owner, spender, value,
  deadline, v, r, s)` signed off-chain is a writable allowance the
  spender can broadcast at will. The user must understand `spender`,
  `value` (especially `type(uint256).max`), and `deadline`.
* **Order signatures** (CowSwap, 0x, Hashflow, etc.) — encode an
  off-chain commitment to swap at certain bounds. Decode `sellToken`,
  `buyToken`, `sellAmount`, `buyAmount`, and `validTo` from the
  typed data; refuse to sign if any field is missing.
* **Account-abstraction `UserOperation`** — encodes a full smart-
  contract call. Decode `callData` end-to-end.

## Approval anti-patterns

1. `approve(spender, type(uint256).max)` — unlimited allowance.
   Surface the literal `uint256.max` value; do not paraphrase as
   "unlimited" without telling the user it is unrevoked until they
   manually revoke.
2. Re-approval without zero-reset — some legacy tokens (USDT
   classic) require `approve(spender, 0)` before `approve(spender,
   newValue)`. Surface the multi-step when needed.
3. Allowance to a router as a one-time setup; allowance to an
   arbitrary EOA is almost always a phishing attempt.
4. `setApprovalForAll(operator, true)` on NFTs — gives the operator
   full custody of every token the user owns now or later in that
   collection. Treat as high-risk.

## Phishing surface

* **Address poisoning** — attacker plants a low/zero-value tx from a
  lookalike address into the user's history. Never pick recipients
  from history; require explicit paste/ENS resolution.
* **Lookalike contracts** — the agent must never resolve "USDC" to
  an arbitrary address it found in a sidecar. Use the
  protocol-skill `contracts.json` as the source of truth.
* **Drainer dApps** — sites that ask for `setApprovalForAll` or
  unlimited `approve` immediately on connect. The wallet's job is to
  show the user what's being signed; the user's job is to refuse.
* **Sign-in-with-Ethereum (SIWE)** — EIP-4361 messages are
  authentication signatures, not transactions. They must still be
  decoded; a malicious site can shape SIWE-looking text to gather a
  signature usable elsewhere if the user signs blind. Always show
  the literal message.

## Counterparty due diligence (limited; surface, don't decide)

* If the user names a contract, look it up in the active skill's
  `contracts.json` and surface `verified: true/false` along with the
  source URL.
* If a contract is unverified or absent from the skill, refuse to
  proceed without explicit user acknowledgment.
* If the destination address is on a known sanctions list (OFAC),
  surface the fact factually — the agent does not decide for the
  user, but the user has a right to know.
