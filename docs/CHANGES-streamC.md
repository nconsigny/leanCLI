# CHANGES — Stream C (drop R1 + Solidity path)

## Part 1 (commit `c4fa2b55`) — non-build artifacts
Deleted `Contracts/` (root Verity proofs, not in lib glob), `solidity/`, `foundry.toml`,
`docs/R1_SEPOLIA.md`, `docs/r1-mainnet-port.md`. `lake build` unaffected.

## Part 2 — Lean core R1 removal (build-guided, green)
- **New** `LeanCli/Ethereum/Chain.lean`: `mainnetChainId`/`sepoliaChainId`/`supportedChainId` (moved
  out of the deleted P256Precompile so SPHINCS/Account keep their chain constants).
- **Deleted modules:** `Ethereum/P256Precompile.lean`, `Contract/R1Account.lean`,
  `Invariants/R1Account.lean`, `Daemon/Server/TpmRpc.lean` (was 100% R1 — generic KEK custody is
  `Keystore/MasterKey.lean`, dispatched under `wallet.`/`eoa.`). Deleted R1 scripts
  `ops/scripts/{r1_sepolia,compile_r1_verity,setup_verity}.sh`.
- **Enums pruned:** `SignerKind.r1`, `SignatureScheme.p256`, `Command.SignR1` (abstract `Invariants/Core`);
  `AccountKind.r1Smart` + R1 defaults (`Wallet/Account`); `ExecuteBatch` r1 arm; `Ethereum/Intent` r1
  variant. Enclave: removed R1-named policies `appleEthereumR1Policy`/`ethereumR1HardwarePolicy`; kept
  generic `appleNativePolicy`, Linux policies, `Curve.p256` + `Backend.supportsCurve`.
- **Daemon/CLI/TUI:** removed `r1.*` dispatch + R1 arms in `AccountRpc`/`ChatRpc`/`Helpers`/`WalletRpc`/
  `MiscRpc`; ~40 R1 sites in `Cli/Runtime`; R1 help/completion in `Cli/Commands`; TUI `CreateR1Flow` +
  `onCreateWallet` `'r1'` union. (TUI `kind:"tpm"` *send/swap* surface removed in part 3.)
- Build: `lake build` **256 jobs** green (was 263; −7 from 4 deleted modules), zero `sorryAx`; `tui`
  `npm run build` + `tsc --noEmit` green.

### Invariant ledger reconciliation (for Stream-F → INVARIANTS.md)
**REMOVED theorems**
- `appleSecureEnclaveAcceptsEthereumR1Signing` (inv **8.4**), `ethereumR1HardwareSigningAccepted` — `Invariants/Keystore.lean`
- `signR1_verified`, `signR1_uses_p256`, `verified_r1_requires_tpm_policy` (R1 half of inv **0.5**) — `Invariants/Core.lean`
- `defaultR1SmartAccepted`, `sepoliaR1SmartAccepted`, `mainnetR1SmartAccepted`, `r1SmartUsesLocalEnclaveWhenAccepted` (**3.3** R1 acceptance) — `Invariants/Account.lean`
- `p256Precompile{InputLength,Address,GasCost}`, `p256{Success,Failure}OutputLength`, `p256{Success,Failure}ResultLength` (**Cat 9 / EIP-7951**) — `Invariants/Mainnet.lean`
- entire `Invariants/R1Account.lean` (**Cat 10**, R1 contract) — module deleted

**KEPT & re-proven** (constructor collapse forced proof reshaping, see below)
- `Invariants/Core.lean`: `signIntent_verified`, `signEOA_verified`, `signEOA_uses_secp256k1`, `verified_*` family, `no_silent_7702_delegation` (7702 half of 0.5), `no_key_exfiltration`.
- `Invariants/Account.lean`: `acceptedSupportedChainOnly`, `acceptedLocalOnly`, `eoaK1UsesBip39WhenAccepted`, `defaultEoaK1Accepted`, `sepoliaEoaK1Accepted`.
- `Invariants/Keystore.lean`: **8.7** (`acceptedSigningRequiresUserAuth`) + generic keystore theorems — confirmed untouched.
- `Invariants/Mainnet.lean`: `p256PrecompileIsMainnetScoped`, `p256PrecompileSupportsSepoliaDev`, `mainnetChainIdSupported`, `sepoliaChainIdSupported` (valid chain-id facts; **names retain `p256` prefix** — Stream-F may rename when reconciling).
- **Cat 12** (`Invariants/SphincsAccount.lean`): untouched (only `open P256Precompile → Chain`).

**Ledger-only**
- **13.8** (P-256 EUF-CMA): no `.lean` theorem of that name exists — pure ledger entry; Stream-F removes it.

**Proof-reshaping note:** collapsing `SignerKind`/`SignatureScheme`/`KeyRef` to single constructors made
the `signerKind = kind` equality trivially true; re-proofs use `by_cases` on `verifiedIntent` directly,
`cases scheme; rfl`, and `<;> first | exact h | exact h.left`. `tpmPolicySatisfied` is now `fun _ => true`
but kept as a `verifiedIntent` conjunct so the signing-gate shape stays stable for a future hardware kind.

## Part 3 — TUI R1 send/swap surface
Remove the `SlotKind "tpm"` (= R1) wallet kind and its `r1.send*` / `tpm.listSepoliaAddresses` dispatch
across the TUI. **Keep** `MasterInitGate`'s `tpm-pin` phase — that is the master-KEK TPM PIN (generic
custody), not R1.
