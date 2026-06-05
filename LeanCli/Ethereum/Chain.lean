/-!
# Chain configuration

Chain identity constants and the small supported-chain predicate the wallet
core uses to gate every signing and simulation decision. Mainnet is the
production target; Sepolia is the explicit dev/testnet target. No other
chain is accepted by the verified core.

These constants were originally hosted in `Ethereum/P256Precompile.lean`;
they are chain facts independent of the (now-removed) P-256/R1 path, so they
live here as a free-standing module that the SPHINCS account, wallet account
policy, and chain invariants all import.
-/

namespace LeanCli.Ethereum.Chain

/-- Ethereum mainnet chain ID (EIP-155). Production target. -/
def mainnetChainId : Nat := 1

/-- Sepolia chain ID (EIP-155). Explicit dev/testnet target; no mainnet
    default is introduced anywhere downstream of this constant. -/
def sepoliaChainId : Nat := 11155111

/-- The set of chains the verified core accepts: mainnet and Sepolia only.
    Every signing/simulation gate narrows an arbitrary `chainId` back to this
    predicate before producing a signature. -/
def supportedChainId (chainId : Nat) : Bool :=
  decide (chainId = mainnetChainId) || decide (chainId = sepoliaChainId)

structure Chain where
  id   : Nat
  name : String
  rpc  : String
  deriving Repr

def mainnet (rpc : String) : Chain := { id := 1,       name := "mainnet",  rpc }

def sepolia (rpc : String) : Chain := { id := 11155111, name := "sepolia", rpc }

end LeanCli.Ethereum.Chain
