# Sepolia R1 Account Dev Flow

This is the dev flow for the Lean/Verity R1 account source in
`Contracts/R1Account/`. The account verifies P-256/R1 signatures with the
EIP-7951 `P256VERIFY` precompile at `0x100`.

Prerequisites:

- A local TPM key, for example `daily`.
- `SEPOLIA_RPC_URL` in the environment.
- `forge`, `cast`, `openssl`, and `python3`.
- `SEPOLIA_DEPLOYER_PRIVATE_KEY` or `PRIVATE_KEY` for temporary dev deployment.

Pin Verity locally:

```bash
./script/setup_verity.sh
```

At the moment upstream Verity pins Lean 4.22.0 while leanCLI pins Lean
4.29.1. The compatibility bridge is tracked by:

```bash
./script/compile_r1_verity.sh
```

Until the Verity compile bridge is complete, `deploy` uses the temporary
Solidity fallback in `solidity/dev/R1AccountDev.sol`. This is for Sepolia
testing only; `Contracts/R1Account/R1Account.lean` remains canonical.
The helper passes `--broadcast` to Foundry so the deployment is actually
sent to Sepolia.

```bash
LEANCLI_TPM_KEY=daily ./script/r1_sepolia.sh deploy
```

The script saves the deployed account address to:

```text
.leancli/keystore/tpm2/daily/r1-account-address.txt
```

Then prepare, sign, and execute a transfer:

```bash
DIGEST=$(./script/r1_sepolia.sh digest <target-address> <value-wei>)
./script/r1_sepolia.sh sign "$DIGEST"
./script/r1_sepolia.sh execute <target-address> <value-wei>
```

Or use the one-shot helper:

```bash
./script/r1_sepolia.sh send <target-address> <value-wei>
```

The same flow is exposed through the main CLI:

```bash
./.lake/build/bin/leancli wallet send sepolia daily <target-address> <value-wei>
```

Preferred daemon-shaped command:

```bash
./.lake/build/bin/leancli daemon daily send sepolia <target-address> <value-eth>
```

Detailed help:

```bash
./.lake/build/bin/leancli daemon help
```

The R1 account must hold enough Sepolia ETH before sending nonzero value.

The `sign` step calls:

```bash
./.lake/build/bin/leancli wallet sign sepolia daily <digest>
```

That requires local `fprintd-verify` before invoking `tpm2_sign`. By default
the CLI asks for `right-index-finger` and retries up to 3 times. Override the
finger with:

```bash
LEANCLI_BIOMETRIC_FINGER=right-thumb ./.lake/build/bin/leancli wallet send sepolia daily <target> <wei>
```

The TPM private blob stays under `.leancli/keystore/tpm2/<name>/` and is
ignored by git.
