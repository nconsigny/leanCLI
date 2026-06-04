# leancli-wallet — operating model

## The verified core vs. the agent

leanCLI has a small, formally-verified core in Lean 4 that owns
every signing decision. Everything outside that core — including this
agent — is treated as untrusted input. The agent proposes; the core
signs only after a human approves at the TUI ConfirmGate.

What the verified core proves (see `INVARIANTS.md` for theorem
names):

* No key-material exfiltration (0.1).
* No raw-bytes signing oracle; only verified typed intents (0.2).
* Wrong-chain signing rejected; chainId must match selected chain
  and observed RPC chainId (0.3).
* Approvals required; signer/path correspondence (0.4).
* R1 signing requires a satisfied TPM policy; EIP-7702 intents need
  explicit delegate approval and chainId ≠ 0 (0.5).
* Balance arithmetic uses `Amount.subChecked`, never raw `Nat.sub`
  (1.1, 1.2).
* Wallet master KEK never leaves the daemon process (8.6).

## Pre-sign pipeline (every signing path goes through this)

```
build {to, value, data}
      ↓
tx.decodeIntent  — ERC-7730 or 4byte fallback → human intent
      ↓
tx.simulate      — eth_call + estimateGas + trace → token transfers
      ↓
ConfirmGate (TUI) — user sees intent + sim outcome + transfers
      ↓
eoa.send / r1.send* — signs + broadcasts
```

The agent's job stops at `propose_send`. It never invokes
`eoa.send`. It never invents a contract address, decimals, balance,
or nonce — call the read tools (`chain_read`, `nonce`, `gas_price`,
`tx.decodeIntent`, `tx.simulate`).

## Signer/path separation

* **EOA (secp256k1)** — a regular BIP-39-derived externally-owned
  account. Used for legacy + EIP-1559 transactions.
* **R1 smart account (P-256)** — local TPM/Secure-Enclave-backed
  smart account. Signing requires a satisfied TPM policy. R1 ops
  flow through ERC-4337 user operations; the on-chain account
  verifies via the EIP-7951 P256VERIFY precompile at `0x100`.

The wallet refuses to substitute one signer kind for another mid-flow.
If the user asks for an action with the wrong signer kind, surface
the constraint; do not silently switch.

## Chain whitelist

The wallet supports **mainnet (1)** and **Sepolia (11155111)** only.
Refuse any task targeting another chain. Do not silently rewrite a
non-Sepolia testnet to Sepolia.

## Nonce monotonicity

Once a nonce `n` has been signed for an account, the wallet never
signs another tx with nonce `≤ n` for that account (invariant 3.2 —
stated, formalized in `LeanCli/Invariants/Nonce.lean`). The agent
must call the `nonce` tool before drafting; do not increment by hand.

## Privacy posture

Network reads are deny-by-default. The `Privacy.NetworkPolicy` model
proves no third-party purposes (analytics, indexers, price quotes)
can leak through. Read more in `docs/PRIVACY_SECURITY.md`.

## Shielded calldata is still calldata

Railgun shields, Privacy Pools deposits, Tornado Cash deposits — all
produce on-chain calldata that the agent must decode at least far
enough that `decodeIntent` produces a meaningful confirmation prompt.
Opacity to the network is not opacity to the user signing the
transaction. Never skip `decodeIntent → simulate → ConfirmGate`.

## Tool surface (subset relevant to wallet hygiene)

| Tool | Purpose |
|---|---|
| `decode_calldata` | Decode `to`/`data` → ERC-7730 intent or 4byte selector |
| `decode_eip712`   | Decode a typed-data payload before signing |
| `tx.simulate`     | eth_call + estimateGas + traced transfers |
| `chain_read`      | Generic policy-gated `eth_call` |
| `nonce`           | Current pending nonce for an address |
| `gas_price`       | Latest observed gas price |
| `propose_send`    | Emit a draft `{to, value, data, chainId}` envelope |
| `protocol_lookup` | Load a protocol skill (Phase 1b) |
| `protocol_function_lookup` | Load a specific function body |
