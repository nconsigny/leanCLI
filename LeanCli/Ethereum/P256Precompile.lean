/-!
# Ethereum P-256/R1 verification precompile

Ethereum account logic can verify local hardware P-256 signatures through
`P256VERIFY` at address `0x100`. Mainnet is the production target; Sepolia
is modeled explicitly for development and hardware-signing tests.
-/

namespace LeanCli.Ethereum.P256Precompile

def mainnetChainId : Nat := 1

def sepoliaChainId : Nat := 11155111

def supportedChainId (chainId : Nat) : Bool :=
  decide (chainId = mainnetChainId) || decide (chainId = sepoliaChainId)

def address : Nat := 0x100

def inputLength : Nat := 160

def gasCost : Nat := 6900

def successOutputLength : Nat := 32

def failureOutputLength : Nat := 0

def fieldModulus : Nat :=
  0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff

def curveA : Nat :=
  0xffffffff00000001000000000000000000000000fffffffffffffffffffffffc

def curveB : Nat :=
  0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b

def basePointX : Nat :=
  0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296

def basePointY : Nat :=
  0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5

def subgroupOrder : Nat :=
  0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551

def cofactor : Nat := 1

structure VerifyInput where
  hash : ByteArray
  r    : ByteArray
  s    : ByteArray
  qx   : ByteArray
  qy   : ByteArray

def wellSized (i : VerifyInput) : Prop :=
  i.hash.size = 32 ∧
    i.r.size = 32 ∧
    i.s.size = 32 ∧
    i.qx.size = 32 ∧
    i.qy.size = 32

def encodedLength (_i : VerifyInput) : Nat := inputLength

structure VerifyScalars where
  h  : Nat
  r  : Nat
  s  : Nat
  qx : Nat
  qy : Nat
  deriving Repr, DecidableEq

def signatureBounds (i : VerifyScalars) : Prop :=
  0 < i.r ∧ i.r < subgroupOrder ∧
    0 < i.s ∧ i.s < subgroupOrder

def publicKeyBounds (i : VerifyScalars) : Prop :=
  i.qx < fieldModulus ∧ i.qy < fieldModulus

def pointAtInfinity (i : VerifyScalars) : Prop :=
  i.qx = 0 ∧ i.qy = 0

def pointOnCurve (i : VerifyScalars) : Prop :=
  (i.qy * i.qy) % fieldModulus =
    (i.qx * i.qx * i.qx + curveA * i.qx + curveB) % fieldModulus

def validInput (i : VerifyScalars) : Prop :=
  signatureBounds i ∧ publicKeyBounds i ∧ pointOnCurve i ∧ ¬ pointAtInfinity i

inductive VerifyResult where
  | success
  | failure
  deriving Repr, DecidableEq

def outputLength : VerifyResult → Nat
  | .success => successOutputLength
  | .failure => failureOutputLength

end LeanCli.Ethereum.P256Precompile
