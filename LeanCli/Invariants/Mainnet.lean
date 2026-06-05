import LeanCli.Ethereum.Chain

/-!
# Ethereum supported-chain invariants

Chain-identity facts the verified core relies on. The theorem names retain
their `p256`-prefixed identifiers to avoid downstream/ledger churn even
though the P-256/R1 path they originally accompanied has been removed; they
assert only chain-id facts (mainnet = 1, Sepolia = 11155111, both supported).
-/

namespace LeanCli.Invariants.Mainnet

open LeanCli.Ethereum.Chain

theorem p256PrecompileIsMainnetScoped :
    mainnetChainId = 1 := by
  rfl

theorem p256PrecompileSupportsSepoliaDev :
    sepoliaChainId = 11155111 := by
  rfl

theorem mainnetChainIdSupported :
    supportedChainId mainnetChainId = true := by
  rfl

theorem sepoliaChainIdSupported :
    supportedChainId sepoliaChainId = true := by
  rfl

end LeanCli.Invariants.Mainnet
