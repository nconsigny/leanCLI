/-!
# secp256k1 specification

The elliptic curve used by Ethereum signatures. We model it as
`y² = x³ + 7` over `𝔽_p` with the standard base point `G` and prime
order `n`.

This module is a pure specification/proof target. Runtime signing, public-key
derivation, recovery, and verification must go through
`LeanCli.Crypto.Secp256k1Native`, which delegates to libsecp256k1 helpers.

Once we bring in Mathlib, we can prove group-law correctness against
`Mathlib.AlgebraicGeometry.EllipticCurve`. For now, scaffolding only.
-/

namespace LeanCli.Crypto.Secp256k1

/-- Field prime of secp256k1. -/
def p : Nat := 0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f

/-- Curve order (prime). -/
def n : Nat := 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141

/-- Affine point with explicit point-at-infinity. -/
inductive Point where
  | infinity
  | affine (x y : Nat)
  deriving Repr, DecidableEq

/-- Standard generator `G`. -/
def G : Point := .affine
  0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
  0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8

/-- ECDSA signature with `v` recovery parameter (EIP-155 adjusted later). -/
structure Signature where
  r : Nat
  s : Nat
  v : UInt8
  deriving Repr, DecidableEq

def modp (x : Nat) : Nat := x % p
def modn (x : Nat) : Nat := x % n

def addMod (m a b : Nat) : Nat := (a + b) % m
def subMod (m a b : Nat) : Nat := (a + m - (b % m)) % m
def mulMod (m a b : Nat) : Nat := (a * b) % m

partial def powModAux (m : Nat) : Nat → Nat → Nat → Nat
  | _base, 0, acc => acc % m
  | base, exp, acc =>
      let acc' := if exp % 2 = 1 then mulMod m acc base else acc
      powModAux m (mulMod m base base) (exp / 2) acc'

def powMod (m base exp : Nat) : Nat :=
  if m = 0 then 0 else powModAux m (base % m) exp 1

/-- Modular inverse for prime moduli via Fermat's little theorem. -/
def invMod (m a : Nat) : Nat :=
  if a % m = 0 then 0 else powMod m a (m - 2)

def pointNeg : Point → Point
  | .infinity => .infinity
  | .affine x y => .affine x (subMod p 0 y)

def pointAdd : Point → Point → Point
  | .infinity, q => q
  | q, .infinity => q
  | .affine x1 y1, .affine x2 y2 =>
      if x1 = x2 then
        if (y1 + y2) % p = 0 then
          .infinity
        else
          let numerator := mulMod p 3 (mulMod p x1 x1)
          let denominator := mulMod p 2 y1
          let slope := mulMod p numerator (invMod p denominator)
          let x3 := subMod p (subMod p (mulMod p slope slope) x1) x2
          let y3 := subMod p (mulMod p slope (subMod p x1 x3)) y1
          .affine x3 y3
      else
        let numerator := subMod p y2 y1
        let denominator := subMod p x2 x1
        let slope := mulMod p numerator (invMod p denominator)
        let x3 := subMod p (subMod p (mulMod p slope slope) x1) x2
        let y3 := subMod p (mulMod p slope (subMod p x1 x3)) y1
        .affine x3 y3

partial def scalarMulAux : Nat → Point → Point → Point
  | 0, _base, acc => acc
  | k, base, acc =>
      let acc' := if k % 2 = 1 then pointAdd acc base else acc
      scalarMulAux (k / 2) (pointAdd base base) acc'

def scalarMul (k : Nat) (point : Point) : Point :=
  scalarMulAux k point .infinity

def lowS (s : Nat) : Nat :=
  if s > n / 2 then n - s else s

/--
Pure ECDSA signing over secp256k1 for an already-hashed message scalar.

The nonce `k` must be uniformly generated or deterministically derived by the
caller (RFC6979/HACL boundary). This function deliberately does not hash or
derive `k`.
-/
def signWithNonce (privateKey digest nonceK : Nat) (recovery : UInt8 := 0) :
    Option Signature :=
  if privateKey = 0 ∨ privateKey ≥ n ∨ nonceK = 0 ∨ nonceK ≥ n then
    none
  else
    match scalarMul nonceK G with
    | .infinity => none
    | .affine x _ =>
        let r := x % n
        if r = 0 then
          none
        else
          let kInv := invMod n nonceK
          let sRaw := mulMod n kInv (addMod n (digest % n) (mulMod n r privateKey))
          let s := lowS sRaw
          if s = 0 then none else some { r, s, v := recovery }

end LeanCli.Crypto.Secp256k1
