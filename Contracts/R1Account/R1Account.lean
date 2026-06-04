/-!
# R1Account Verity contract

This is the Lean/Verity source-of-truth for the Sepolia R1 account. It is
kept separate from the `LeanCli` Lake target until Verity is added as a
toolchain dependency.

The contract stores a P-256 public key and nonce. Execution requires a
P-256/R1 signature over the operation digest, verified by an external
`P256VERIFY` oracle that the Verity compilation/linking path should lower to
the EIP-7951 precompile at `0x100`.
-/

import Verity.Core
import Verity.Core.Semantics
import Verity.EVM.Uint256

namespace Contracts.R1Account

open Verity
open Verity.EVM.Uint256

def qxSlot : StorageSlot Uint256 := ⟨0⟩
def qySlot : StorageSlot Uint256 := ⟨1⟩
def nonceSlot : StorageSlot Uint256 := ⟨2⟩

def sepoliaChainId : Uint256 := 11155111

/--
External digest oracle for the account operation.

The intended linked implementation is:
`keccak256(abi.encode("leanCLI.r1.sepolia.execute", address(this),
chainId, nonce, target, value, dataHash))`.
-/
def operationDigest
    (self target : Address)
    (chainId nonce value dataHash : Uint256) : Contract Uint256 := fun s =>
  ContractResult.success
    ((Verity.Env.ofWorld s).callOracle
      "LeanCli_R1_operationDigest"
      [chainId, nonce, value, dataHash])
    s

/--
External P-256 verification oracle.

The intended linked implementation calls EIP-7951 `P256VERIFY` at `0x100`
with `h || r || s || qx || qy` and returns `1` on success.
-/
def p256Verify
    (h r sigS qx qy : Uint256) : Contract Bool := fun s =>
  ContractResult.success
    (((Verity.Env.ofWorld s).callOracle
      "LeanCli_R1_p256Verify"
      [h, r, sigS, qx, qy]) == 1)
    s

def initialize (qx qy : Uint256) : Contract Unit := do
  setStorage qxSlot qx
  setStorage qySlot qy
  setStorage nonceSlot 0

/--
Accept a signed operation and advance the nonce.

The actual value transfer/external call is intentionally left to the Verity
linking/codegen layer once external call support is wired. This Lean source
proves the critical R1 authorization and nonce transition first.
-/
def execute
    (target : Address)
    (value dataHash r sigS : Uint256) : Contract Unit := do
  let n ← getStorage nonceSlot
  let self ← contractAddress
  let qx ← getStorage qxSlot
  let qy ← getStorage qySlot
  let h ← operationDigest self target sepoliaChainId n value dataHash
  let ok ← p256Verify h r sigS qx qy
  require ok "invalid P-256 signature"
  setStorage nonceSlot (add n 1)

end Contracts.R1Account
