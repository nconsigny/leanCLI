# Privacy And Security

leanCLI is designed around a narrow network boundary:

- The CLI talks only to the local daemon over loopback.
- Strict daemon mode uses local/light-client provider access only.
- Configured-node access requires Tor mode.
- Broadcast is limited to `eth_sendRawTransaction`.
- Endpoint configuration rejects credentialed/API-key endpoints.
- Third-party APIs are not wallet dependencies.

## Denied Surfaces

The following categories are denied by policy and should not be added as
defaults, fallbacks, or convenience features:

- Analytics and telemetry.
- Crash-report uploads.
- Price quote APIs.
- Fiat/onramp APIs.
- Metadata and indexer APIs.
- Peer discovery services.
- Hosted RPC endpoints that require API keys.
- Any direct CLI-to-node path.

## Mode Semantics

`strict` mode:

- Allows local node reads over loopback.
- Allows local raw transaction broadcast over loopback.
- Denies all configured-node traffic.
- Denies all third-party peers and third-party purposes.

`tor` mode:

- Allows local loopback provider access.
- Allows configured-node reads and broadcasts over Tor.
- Denies direct configured-node reads.
- Denies third-party peers and credentialed endpoints.

`deny` mode:

- Denies every request.

## Sidecar trust model

The daemon spawns three Node sidecars (`bridge/`, `bridge/clearsign/`,
`bridge/llm/`) for work that needs heavy JS dependencies (snarkjs, viem,
Anthropic SDK). Every sidecar is treated as **untrusted**:

- Sidecars never sign. Outputs are JSON, re-validated and re-decoded
  Lean-side before any signing path is reached.
- The LLM agent's drafted txs flow through the same `tx.decodeIntent` +
  `tx.simulate` + TUI `ConfirmGate` as pasted calldata — no fast path.
- Sidecar chain reads (`bridge/llm/src/daemon-callback.mjs`) loop back
  through the daemon's policy-gated `chain.*` RPCs, so they obey the same
  `strict` / `tor` / `deny` boundaries as CLI requests. Sidecars cannot
  reach the network independently.

An adversarial model output, prompt injection, or compromised sidecar can
at worst produce confusing simulations the user rejects in the
`ConfirmGate`. There is no path from a sidecar to a signed transaction that
bypasses user confirmation.

## Invariant Modules

- `LeanCli.Invariants.Network`

These modules prove the current policy boundaries used by the CLI and
daemon models.
