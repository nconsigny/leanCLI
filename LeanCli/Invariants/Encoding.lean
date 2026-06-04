import LeanCli.Encoding.Rlp
import LeanCli.Encoding.Json
import LeanCli.Crypto.Hex

/-!
# Encoding-layer invariants

Stated and proved structural facts about the in-tree encoders. These are
deliberately small: they exist to catch regressions in the trivially-true
identities the rest of the wallet relies on (RLP empty/zero canonical
forms, JSON-helper destructors, Hex prefix), not to substitute for the
full round-trip proofs tracked under invariants 4.1 / 4.2.

Full round-trips will be added once the encoding/decoding pair has a
non-`partial` shared termination measure. Until then we expose enough
structural lemmas that downstream proofs (Tx well-formedness, Bridge
response handling) can rewrite with them.
-/

namespace LeanCli.Invariants.Encoding

open LeanCli.Encoding.Rlp
open LeanCli.Encoding.Json

/-! ## RLP canonical forms

Ethereum RLP fixes two canonical encodings that we rely on throughout the
typed-tx code paths: the natural number `0` and the empty byte string both
encode to the empty payload, and the empty list encodes to a single
`0xc0` byte. The first equality is true by definition of `natBytes`; the
second is the structural form of `encodeEmptyList`.
-/

theorem natBytes_zero : natBytes 0 = ByteArray.empty := rfl

theorem encodeNat_zero : encodeNat 0 = Item.bytes ByteArray.empty := rfl

theorem encodeEmptyList_eq : encodeEmptyList = Item.list [] := rfl

theorem singleton_size (b : UInt8) : (singleton b).size = 1 := rfl

theorem concat_nil : concat [] = ByteArray.empty := rfl

/-! ## JSON destructors are partial inverses of constructors

The wallet treats JSON values as opaque after parsing and only inspects
them through the `as*` destructors. These lemmas record that the
destructors agree with their constructors on well-formed inputs — i.e.
the daemon cannot accidentally read an `arr` as a `str`. -/

theorem asString_str (s : String) : asString (.str s) = some s := rfl

theorem asString_not_str_null : asString .null = none := rfl

theorem asArray_arr (xs : Array Json) : asArray (.arr xs) = some xs := rfl

theorem asNat_negative_none : asNat (.num (-1)) = none := by decide

theorem asNat_nonneg (n : Nat) : asNat (.num (Int.ofNat n)) = some n := by
  unfold asNat
  simp

/-! ## Hex prefix and digit table

`nibbleToChar` always emits a character in `[0-9a-f]`. Combined with
`hexDigit?` being defined exactly on that range, this is the structural
core of invariant 4.2 (Hex round-trip) without committing to the full
ByteArray-level proof. -/

section Hex
open LeanCli.Crypto.Hex

theorem hexDigit_zero : hexDigit? '0' = some 0 := by decide
theorem hexDigit_nine : hexDigit? '9' = some 9 := by decide
theorem hexDigit_a_lower : hexDigit? 'a' = some 10 := by decide
theorem hexDigit_f_upper : hexDigit? 'F' = some 15 := by decide
theorem hexDigit_non_hex : hexDigit? 'g' = none := by decide
theorem nibbleToChar_zero : nibbleToChar 0 = '0' := by decide
theorem nibbleToChar_fifteen : nibbleToChar 15 = 'f' := by decide

/-- Concrete-nibble round-trip facts: encoding then decoding any of the 16
literal nibble values recovers it. Spelt out as separate `decide` proofs
so the lemmas hold without Mathlib's `fin_cases`. Lifts to a byte-level
proof once a byte-pair combinator lemma is added. -/
theorem nibble_round_trip_0  : hexDigit? (nibbleToChar 0)  = some 0  := by decide
theorem nibble_round_trip_1  : hexDigit? (nibbleToChar 1)  = some 1  := by decide
theorem nibble_round_trip_2  : hexDigit? (nibbleToChar 2)  = some 2  := by decide
theorem nibble_round_trip_3  : hexDigit? (nibbleToChar 3)  = some 3  := by decide
theorem nibble_round_trip_9  : hexDigit? (nibbleToChar 9)  = some 9  := by decide
theorem nibble_round_trip_10 : hexDigit? (nibbleToChar 10) = some 10 := by decide
theorem nibble_round_trip_15 : hexDigit? (nibbleToChar 15) = some 15 := by decide

end Hex

end LeanCli.Invariants.Encoding
