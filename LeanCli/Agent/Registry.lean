import LeanCli.Agent.Tools
import LeanCli.Agent.ToolDefs.Decode
import LeanCli.Agent.ToolDefs.Simulate
import LeanCli.Agent.ToolDefs.Chain
import LeanCli.Agent.ToolDefs.Propose
import LeanCli.Agent.ToolDefs.Protocols
import LeanCli.Agent.ToolDefs.TrustedRegistry
import LeanCli.Agent.ToolDefs.SlotLookup
import LeanCli.Agent.ToolDefs.Ens
import LeanCli.Agent.ToolDefs.Tokens
import LeanCli.Agent.ToolDefs.UniV3Swap
import LeanCli.Agent.ToolDefs.Aave
import LeanCli.Agent.ToolDefs.Numeric
import LeanCli.Agent.ToolDefs.Shielded
import LeanCli.Agent.ToolDefs.Approvals

/-!
# Default tool registry

Phase 0 baseline: 7 read/propose tools mapping 1:1 to existing
daemon RPCs. Phase 1b adds `protocol_lookup` and
`protocol_function_lookup`, both backed by an in-process
`Skills.Registry` opened at startup.

Splitting this out from `Agent.Loop` keeps the loop module
dependency-light and makes it obvious where the tool inventory
lives. The one-shot `leancli-agent` keeps the Phase-0-only `default`
registry; the persistent `leancli-agentd` builds a Phase-1b registry
via `defaultWithSkills` and threads the skills `IO.Ref` through.
-/

namespace LeanCli.Agent.Registry

open LeanCli.Agent.Tools
open LeanCli.Agent.ToolDefs

/-- The Phase-0 registry, plus the Phase-1d trusted-registry read
    tool. Used by one-shot `leancli-agent` where the lifetime of the
    skills registry is not worth the IO overhead per spawn.

    The trusted-registry tool is registered globally (rather than only
    in `defaultWithSkills`) because the answer to "which addresses are
    yours" is part of the agent's baseline context regardless of
    whether the skills layer is loaded — see
    `docs/PHASE1D_THREAT_MODEL.md` §5 (address spoofing). -/
def default : ToolRegistry := [
  Decode.decodeCalldata,
  Decode.decodeEip712,
  Simulate.txSimulate,
  Chain.chainRead,
  Chain.nonce,
  Chain.gasPrice,
  Propose.proposeSend,
  TrustedRegistry.trustedRegistryList,
  SlotLookup.slotLookup,
  -- ENS forward resolution (vitalik.eth → 0x…). Forwards to daemon RPC
  -- `chain.resolveName` so the agent resolves names itself instead of
  -- stalling to ask the user. Read-only, mainnet-canonical, no chainId
  -- arg (so it never trips the chain-whitelist pin).
  Ens.ensResolve,
  -- Token-registry trio: addresses + decimals + unit conversions from
  -- a compiled-in, hand-audited list so the LLM never invents them
  -- from training data. Read-only, no daemon RPC, no signing path.
  Tokens.tokenLookup,
  Tokens.toBaseUnitsTool,
  Tokens.humanUnitsTool,
  -- Approval-audit pair. `audit_approvals` forwards to the daemon's
  -- cross-dApp `Approval`-log scan (`daemon.approvals.list`) so the LLM
  -- discovers allowances instead of guessing a spender list;
  -- `check_allowance` reads one owner→spender pair via `chain.ethCall`
  -- with correctly-encoded calldata. Both read-only, never sign.
  Approvals.auditApprovals,
  Approvals.checkAllowance,
  -- Typed ERC-20 approve builder: the daemon-side encoder lays out the
  -- calldata so the model never hand-writes the spender/amount words (a
  -- transposed nibble there silently approves the wrong spender). Pairs
  -- with the sign-time address-integrity gate (Daemon/Server/AddrGuard).
  Approvals.prepareErc20Approve,
  -- One-shot Uniswap V3 swap builder (commit 2 of the swap-snappiness
  -- plan): forwards to daemon RPC `swap.prepareUniswapV3` so the LLM
  -- never recomputes a quote, allowance, or swap calldata by hand.
  UniV3Swap.prepareUniswapV3Swap,
  -- Aave V3 Pool actions. Five typed tools (supply / withdraw / borrow
  -- / repay / setCollateral), all forwarded to daemon RPC `aave.prepare`
  -- so the daemon owns allowance reads + ABI encoding and the LLM only
  -- chooses a tool + fills its arguments.
  Aave.prepareAaveSupply,
  Aave.prepareAaveWithdraw,
  Aave.prepareAaveBorrow,
  Aave.prepareAaveRepay,
  Aave.prepareAaveSetCollateral,
  -- Pure numeric utilities. No IO, no daemon round-trip — they exist
  -- so the model has somewhere to hand off hex/decimal conversions
  -- and basis-point slippage math instead of doing prose arithmetic.
  Numeric.hexToUint,
  Numeric.uintToHex,
  Numeric.applySlippage,
  -- Shielded action tools (PR 3 of the privacy slice). Privacy Pool +
  -- Railgun typed wrappers around the existing `shielded.*` daemon
  -- RPCs so the LLM-driven path doesn't need to free-form propose_send
  -- hex for shielded calldata. Tornado tools land in PR 2.
  Shielded.preparePrivacyPoolDeposit,
  Shielded.preparePrivacyPoolWithdraw,
  Shielded.prepareRailgunShield,
  Shielded.prepareRailgunUnshield,
  Shielded.prepareRailgunTransfer,
  -- Tornado Cash drafting (PR 2). Sidecar is stubbed until snarkjs +
  -- Baby Jubjub Pedersen lands; the typed tools surface a clear
  -- daemon_error until then.
  Shielded.prepareTornadoDeposit,
  Shielded.prepareTornadoWithdraw
]

/-- Phase-1b registry: the Phase-0 surface plus the two
    skills-backed lookup tools. The caller provides the `IO.Ref` so
    the daemon's `reload` op can swap the registry under both tools
    atomically. -/
def defaultWithSkills (regRef : Protocols.RegistryRef) : ToolRegistry :=
  default ++ [
    Protocols.protocolLookup regRef,
    Protocols.protocolFunctionLookup regRef
  ]

end LeanCli.Agent.Registry
