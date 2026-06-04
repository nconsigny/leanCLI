import LeanCli.Ethereum.Tx

/-!
# Transaction well-formedness

A transaction is "well-formed" when:
  * `gasLimit ≥ 21_000` (intrinsic gas for a bare transfer)
  * `maxFeePerGas ≥ maxPriorityFeePerGas`
  * `chainId` matches the configured chain
  * `value` fits in 256 bits (we'll tighten this when we move to `UInt256`)

Additional invariants per operation type will be layered on top.
-/

namespace LeanCli.Invariants.TxWellFormed

open LeanCli.Ethereum.Tx

def wellFormed (tx : TxEip1559) (chainId : Nat) : Prop :=
  tx.chainId = chainId
  ∧ tx.gasLimit ≥ 21000
  ∧ tx.maxPriorityFeePerGas ≤ tx.maxFeePerGas
  ∧ tx.value < 2 ^ 256

end LeanCli.Invariants.TxWellFormed
