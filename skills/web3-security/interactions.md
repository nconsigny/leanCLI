# web3-security — interaction patterns the agent should reinforce

## Always decode before signing

For any tx that the user wants to sign, the agent runs
`decode_calldata` and surfaces the ERC-7730 intent (or 4byte
fallback) **before** `propose_send`. If `decode_calldata` returns no
match, treat the call as opaque and refuse to draft until a skill or
the user can supply context.

## Always simulate before signing

`tx.simulate` produces `eth_call` + `eth_estimateGas` + (when
available) a transfers block. The transfers block tells the user
which token movements would happen. Refuse to propose if the
simulator rejects (revert) — surface the revert reason verbatim.

## Always show the chainId

Every `propose_send` payload carries `chainId`. The TUI ConfirmGate
displays it; the agent should also restate it in its final text
response so a user reading just the chat sees what chain they were
about to use.

## Confirm address ownership for receivers

If a user says "send to my second wallet", call the daemon's
`address.resolve` (or, in the Phase 1b world, ask for the address
explicitly). Address ownership is proved by re-deriving the address
from a known seed at a known path (invariant 14.1) — the
verified-witness shape is the only way the wallet trusts an "owned"
claim.

## Surface the security model, do not hide it

When the user asks an action that triggers refusal, explain *why*
in terms of the model: "I can't sign this because the chain id is 8453
(Base); only mainnet (1) and Sepolia (11155111) are supported."
Vague refusals make users move to a different wallet.
