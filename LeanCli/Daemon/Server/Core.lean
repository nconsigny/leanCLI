import LeanCli.Network.Policy
import LeanCli.RPC.Outbound
import LeanCli.Sphincs.Bridge

/-!
# Daemon server core types

Pure type declarations hoisted out of `LeanCli/Daemon/Server.lean`
so the family-specific RPC modules under `LeanCli/Daemon/Server/`
can share them without re-introducing the monolith.

No IO, no helpers — only structures and their `Repr` instances live here.
-/

namespace LeanCli.Daemon.Server

open LeanCli.Network.Policy

/-- A single configured indexer entry. URL is persisted to disk; the API
    key is supplied via env (e.g. `LEANCLI_ETHERSCAN_KEY`) and never
    written to the config file. -/
structure IndexerEntry where
  name : String
  url  : String
  deriving Repr

/-- Per-chain SPHINCS- verifier contract address, keyed by parameter set.
    The on-chain `SphincsAccount` contract delegates `verify(...)` to this
    address via `staticcall`, so an account on chain `chain` with param set
    `paramSet` must target the matching deployed verifier. Phase 2 ships the
    schema only; concrete addresses stay `none` until Phase 4's Sepolia
    deployment lands. -/
structure SphincsVerifierEntry where
  chain    : String
  paramSet : LeanCli.Sphincs.ParamSet
  /-- Lower-case `0x...` hex address as written in the JSON config; the
      daemon RPC layer will validate it on first use. `none` here means
      the user has not configured a verifier for this `(chain, paramSet)`
      pair, and any signing flow under that pair must fail closed. -/
  address  : Option String
  deriving Repr

structure Config where
  socketPath : String
  chainId    : Nat
  policy     : Policy
  rpcEndpoint : LeanCli.RPC.Outbound.Endpoint
  -- Why: ENS resolution targets mainnet regardless of the operating chain.
  -- Optional: if `none`, ENS requests fail with -32030 (no silent fallback).
  ensRpcEndpoint : Option LeanCli.RPC.Outbound.Endpoint := none
  -- Why: per-chain RPC endpoints picked at call time. Keys are user-supplied
  -- chain names ("mainnet", "sepolia", ...). When a request omits `chain`,
  -- `rpcEndpoint` is used. When `chain` is supplied and missing here, the
  -- handler must fail closed rather than fall back to a different chain.
  chainEndpoints : Array (String × LeanCli.RPC.Outbound.Endpoint) := #[]
  indexers   : Array IndexerEntry := #[]
  -- Why: per-(chain, paramSet) SPHINCS- verifier address map. Read by
  -- Phase 3 daemon RPCs (`sphincs.create`, `sphincs.send`, ...). Empty by
  -- default; populated from `daemon.json`'s `sphincs_verifiers` block.
  sphincsVerifiers : Array SphincsVerifierEntry := #[]
  -- Why: per-(chain, paramSet) SPHINCS- factory address map. Re-uses
  -- `SphincsVerifierEntry` because the per-row shape is identical
  -- (chain × paramSet → optional address). Read by
  -- `sphincs.account.computeAddress` and `sphincs.account.deploy` —
  -- both fail closed when no factory is configured. Populated from
  -- `daemon.json`'s `sphincs_factories` block.
  sphincsFactories : Array SphincsVerifierEntry := #[]
  -- Why: per-chain ERC-4337 bundler URL (the UserOp submission
  -- endpoint, e.g. Candide). Bundler is paramSet-agnostic — one URL
  -- handles every paramSet on that chain — so the key is just the
  -- chain name. Read by `sphincs.account.send`; populated from
  -- `daemon.json`'s `sphincs_bundlers` block.
  sphincsBundlers : Array (String × String) := #[]
  -- Why: hard cap on the number of BIP-44 indices the trusted-registry
  -- RPC (`wallet.lean_verified_addresses`, Phase 1d) will enumerate per
  -- path. Lower = stricter forward-privacy at the cost of less context
  -- in the agent's system prompt. The handler clamps user-supplied
  -- `count` to this value; a request for more is silently capped, not
  -- errored. See `docs/PHASE1D_THREAT_MODEL.md` §2 for the rationale.
  trustedRegistryMaxPerPath : Nat := 5

instance : Repr Config where
  reprPrec cfg _ :=
    "Config(socketPath := " ++ repr cfg.socketPath ++
      ", chainId := " ++ repr cfg.chainId ++
      ", policy := <function>)"

end LeanCli.Daemon.Server
