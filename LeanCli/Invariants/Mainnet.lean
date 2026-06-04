import LeanCli.Ethereum.P256Precompile

/-!
# Ethereum chain and P256VERIFY invariants
-/

namespace LeanCli.Invariants.Mainnet

open LeanCli.Ethereum.P256Precompile

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

theorem p256PrecompileInputLength :
    inputLength = 160 := by
  rfl

theorem p256PrecompileAddress :
    address = 0x100 := by
  rfl

theorem p256PrecompileGasCost :
    gasCost = 6900 := by
  rfl

theorem p256SuccessOutputLength :
    successOutputLength = 32 := by
  rfl

theorem p256FailureOutputLength :
    failureOutputLength = 0 := by
  rfl

theorem p256SuccessResultLength :
    outputLength VerifyResult.success = 32 := by
  rfl

theorem p256FailureResultLength :
    outputLength VerifyResult.failure = 0 := by
  rfl

end LeanCli.Invariants.Mainnet
