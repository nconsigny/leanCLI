# R1 mainnet port

Tracking doc for extending R1/TPM signing to Ethereum mainnet. R1 is currently
pinned to Sepolia at the daemon RPC and shell-script layer; the precompile and
contract sides are already mainnet-ready.

## Why this is now tractable

[EIP-7951](https://ethereum-magicians.org/t/eip-7951-precompile-for-secp256r1-curve-support/24360)
(the `P256VERIFY` precompile at `0x100`, 6900 gas) is **live on mainnet**. The
earlier blocker — that pure-Solidity P-256 verification would cost ~330k gas /
~$30+ per send — is gone. R1 sends on mainnet now cost the same gas as on
Sepolia.

## What is already mainnet-ready

- **Lean precompile model** — `LeanCli/Ethereum/P256Precompile.lean:18,22`
  encodes `address := 0x100` and `gasCost := 6900`, matching EIP-7951
  exactly. `supportedChainId` already returns `true` for both mainnet (1) and
  Sepolia.
- **R1 smart-account contract** — `solidity/dev/R1AccountDev.sol:69` does
  `staticcall(6900, 0x100, ...)`. There is **no Solidity fallback**: the
  `require` on line 73 fails if the precompile isn't there. The contract works
  on any EIP-7951-enabled chain as deployed, with no source change.
- **TPM signing primitive** — `signSepoliaDigest` in
  `LeanCli/Keystore/Tpm2Runtime.lean:450` is misnamed; the implementation
  just signs a 32-byte digest with PIN auth and is chain-agnostic. The comment
  at `Tpm2Runtime.lean:362` already acknowledges this ("usable on any
  EIP-7951–enabled chain; chain selection happens at deploy").
- **Network policy** — `LeanCli/Privacy/NetworkPolicy.lean` is already
  chain-aware (`mainnetSafeDaemonPolicy`); no R1-specific carve-out is
  required.
- **Daemon chain selector** — accepts `mainnet` for EOA flows already
  (`LeanCli/Cli/Runtime.lean:1894`).

## What is sepolia-pinned (the plumbing to change)

1. **Shell script** — `script/r1_sepolia.sh`
   - Hardcodes `SEPOLIA_RPC_URL` (lines 124, 144, 206, 285).
   - Stores the R1 smart-account address in a single, chain-unqualified file
     `${KEY_DIR}/r1-account-address.txt` (line 16).
   - Help text & `wallet sign sepolia` subcommands assume sepolia (lines 238,
     258).
   - Contains a stale "temporary Solidity fallback" comment (line 317) that no
     longer reflects the contract (which is precompile-only).

2. **Daemon RPC methods** — `LeanCli/Daemon/Server.lean`
   - `r1.sendSepolia` (line 1901), `r1.sendEthSepolia` (line 1911),
     `r1.sendRawSepolia` (line 1921), `tpm.signSepolia` (line 1892) all call
     `r1SendFlow` which shells out to `r1_sepolia.sh`.
   - `r1SendFlow` (line 1335) takes no chain parameter.
   - `tpm.listSepoliaAddresses` (line 1876) — TUI uses this for the TPM rows
     in WalletsHub; returns the sepolia-specific R1 account address.

3. **TUI guards** — drop / generalize:
   - `tui/src/screens/WalletsHub.tsx:121,233,397` — TPM pinned to sepolia in
     the chain cycle, the balance fetch, and the chain passed to onPick.
   - `tui/src/screens/SwapFlow.tsx:197-198,234-237` — `isR1` excludes mainnet
     from the swap chain cycle.
   - `tui/src/screens/SendFlow.tsx:329` — hardcodes
     `method="r1.sendEthSepolia"`.
   - `tui/src/screens/SendRawFlow.tsx:288` — hardcodes
     `method="r1.sendRawSepolia"`.

4. **CLI help text & docs**
   - `LeanCli/Cli/Commands.lean:779` — "sepolia today; mainnet is
     intentionally disabled until production R1 deployment".
   - `LeanCli/Cli/Commands.lean:776,792,795,832,833` — example commands and
     script references all reference `r1_sepolia.sh` / `sepolia`.
   - `docs/R1_SEPOLIA.md` — sepolia-specific dev flow; rename or add a
     mainnet sibling.

## Plumbing change set (proposed bundled PR on `leanAI`)

| # | Change | File(s) | Effort |
|---|---|---|---|
| 1 | Generalize shell script: `r1_sepolia.sh` → `r1.sh` (or env-driven). Replace `SEPOLIA_RPC_URL` with `RPC_URL`. Per-chain account file `r1-account-<chain>.txt`. | `script/r1_sepolia.sh`, callers | S |
| 2 | Add chain param to `r1SendFlow`. Plumb through to the script invocation (`RPC_URL` env, chain-qualified account file). | `LeanCli/Daemon/Server.lean:1335` | S |
| 3 | Add chain-aware daemon RPC methods. Either add `r1.sendEth` / `r1.sendRaw` / `tpm.sign` accepting `chain`, or add `*Mainnet` siblings. Recommendation: parameterize, not sibling — sibling explosion is what got us here. | `LeanCli/Daemon/Server.lean:1892,1901,1911,1921` | S–M |
| 4 | Make `tpm.listSepoliaAddresses` chain-aware (new RPC `tpm.listAddresses` taking `chain`, or surface both addresses). | `LeanCli/Daemon/Server.lean:1876` | S |
| 5 | Drop / generalize TUI sepolia guards; route TUI calls through new chain-aware RPCs. | `tui/src/screens/{WalletsHub,SwapFlow,SendFlow,SendRawFlow}.tsx` | S |
| 6 | Rename `signSepoliaDigest` → `signDigest`. Update CLI help text & stale "temporary Solidity fallback" comment. | `LeanCli/Keystore/Tpm2Runtime.lean:450`, `LeanCli/Cli/Commands.lean:776-833`, `script/r1_sepolia.sh:317` | S |
| 7 | Doc: add `docs/R1_MAINNET.md` or rename `docs/R1_SEPOLIA.md` to be chain-neutral. | `docs/` | S |

Total: roughly a day of plumbing. No proofs invalidated — the abstract
`Invariants/` tree is chain-agnostic, and `Invariants/Mainnet.lean` already
proves `sepoliaChainIdSupported` and the mainnet counterpart.

## Operational steps (one-time, out of CLI scope)

- **Deploy `R1AccountDev` to mainnet**, once per user. Same bytecode; needs
  the user's `QX`/`QY` baked in at construction (matches sepolia deploy
  flow). Deployment gas is the only material cost.
- **Fund the relayer EOA on mainnet.** Each `execute()` call needs gas
  (relayer pays). Per-send budget: ~6900 (precompile) + ~21k (base) + call
  gas. Negligible compared to the old Solidity verifier path.

## Open questions

- **R1 mainnet contract authority** — the sepolia contract address is stored
  in `r1-account-address.txt` per key. On mainnet, do we want the same
  per-user contract model, or a singleton factory? Per-user keeps the
  threat model identical to sepolia; a factory adds shared trust surface.
  Recommendation: per-user, mirror sepolia.
- **Default chain for new R1 keys** — once mainnet is supported, what
  should `wallet create r1 <name>` default to? Recommendation: leave it
  sepolia-default; require an explicit `--chain mainnet` flag for the
  first year so accidental mainnet deploys don't burn user ETH.
- **Should `r1.sendRaw` / `r1.sendEth` keep sepolia in the method name?**
  Recommendation: introduce chain-parameterized methods, keep the existing
  `*Sepolia` methods as thin wrappers for one release for backwards
  compatibility, then remove.

## Status

- [ ] Step 1 — shell script generalization
- [ ] Step 2 — `r1SendFlow` takes chain
- [ ] Step 3 — chain-aware daemon RPCs
- [ ] Step 4 — chain-aware TPM listing
- [ ] Step 5 — TUI guard removal
- [ ] Step 6 — renames + stale-comment cleanup
- [ ] Step 7 — docs update
- [ ] Op — mainnet contract deploy + relayer funding
