# R1Account Verity Source

This directory is the intended source of truth for the Sepolia R1 smart
account. The Solidity version was removed so the contract behavior lives in
Lean first.

Current status:

- `R1Account.lean` defines the Verity-style implementation.
- `Spec.lean` states the initialization and accepted/rejected execution
  behavior.
- `Invariants.lean` names nonce and public-key invariants.
- `Proofs/Basic.lean` starts the proof surface.

Verity is pinned by `script/setup_verity.sh`. The repo does not import it in
the default Lake graph yet because upstream Verity currently pins Lean 4.22.0
while leanCLI pins Lean 4.29.1. The next integration step is to bridge that
toolchain gap, compile this contract to Yul/EVM, and wire
`LeanCli_R1_p256Verify` to EIP-7951 `P256VERIFY` at `0x100`.
