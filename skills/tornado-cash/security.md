# tornado-cash — security

## Status

leanCLI does not yet ship a `@kohaku-eth/tornado-cash` SDK. Drafting
Tornado Cash transactions through the agent is **coming soon**. Until
then, this skill is loaded for **decode context only**: the agent
recognizes Tornado Cash calldata and explains it through the standard
ConfirmGate, but does not yet produce outgoing deposits / withdrawals.

For shielded ETH today the agent uses Privacy Pool
(`@kohaku-eth/privacy-pools`) or Railgun (`@kohaku-eth/railgun`).

## What the agent does today

| Request | Agent action |
|---|---|
| "What is Tornado Cash?" | Explain (see `overview.md`). |
| "Decode this calldata, it might be Tornado." | Decode via `abi/ETHTornado.json` + 4byte fallback; render through ConfirmGate. |
| "How does Tornado differ from Privacy Pools?" | Compare; suggest Privacy Pool / Railgun for active use today. |
| "Draft a 1 ETH deposit." | Tell the user it is coming soon; suggest Privacy Pool or Railgun via the Privacy menu. |
| "Generate a Tornado note for me." | Coming soon (waits on the SDK). |
| "Submit my proof to a Tornado relayer." | Coming soon (relayer plumbing lands with the SDK). |

## Engineering posture once the SDK lands

When `@kohaku-eth/tornado-cash` lands, the integration follows the same
shape as Privacy Pool and Railgun:

* Witness / proof generation in the untrusted Node sidecar.
* The Lean daemon never trusts the sidecar's output — every Tornado
  calldata blob flows through `decodeIntent → simulate → ConfirmGate`
  before any signature is produced.
* Note material persists in an encrypted shielded-secret store modeled
  on the existing PP and Railgun stores.
* Relayer endpoints are user-configurable; the daemon's network policy
  gates which endpoints the sidecar may reach.

## Decode-time behaviour

When the agent decodes a Tornado Cash calldata blob today (because
the user pasted one, or `SendRawFlow` is decoding an incoming tx
that references one of the pool addresses):

1. Identify the function from `abi/ETHTornado.json` (or the 4byte
   directory if the ABI stub is empty).
2. Pretty-print the call.
3. Render the decoded view through ConfirmGate. The user approves at
   the gate as with any other tx.

## "Coming soon" surface

The chat regex parser, the Privacy menu, and any agent response that
encounters an outgoing Tornado Cash draft today say **"coming soon"**
and point at Privacy Pool / Railgun as the active alternatives.
