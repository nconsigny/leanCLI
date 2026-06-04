/-!
# Address-ownership witness

Captures what the daemon learned about an address that appeared in a
`RegexDraft` field (`to`, `from`, `spender`, …) when resolving local
references. The TUI renders these as per-field badges in the transaction
proposal box so the user can see at a glance whether a referenced
wallet was actually re-derived from its seed (proving control) or
merely looked up from a record on disk.

The accompanying invariant lives at
`LeanCli.Invariants.AddressOwnership`. There we prove (against a
pure abstract resolver model that mirrors the daemon's IO function)
that emitting `Status.verified path` is only possible along a code
path that re-derived `path` from a seed and structurally compared the
output to the resolved address. The secp256k1/HMAC/keccak primitives
stay opaque (axiomatized at the FFI boundary).
-/

namespace LeanCli.Ethereum.Ownership

inductive Status where
  /-- Re-derived from an unlocked BIP-39 seed at the recorded path;
      EIP-55 address structurally compared and matched. -/
  | verified (path : String)
  /-- EOA exists in the on-disk store but no unlocked seed is in
      memory, so we couldn't re-derive at draft time. The proposal
      still renders the address (from the record) but flags the
      ownership claim as unverified. -/
  | locked
  /-- TPM-wrapped R1/SPHINCS+ key — owned via the keystore but not
      BIP-39-derivable. Distinct from `verified` because the proof of
      possession involves a hardware unwrap, not a re-derivation. -/
  | hardware
  /-- Address-book label match. Not a wallet we control; the user just
      gave it a friendly name. -/
  | book
  /-- 0x literal that didn't match any wallet or book entry. -/
  | external
  /-- The re-derived address disagreed with the on-disk record. This
      is a bug (or tampering) — the proposal must surface it and the
      sign path must refuse. -/
  | mismatch (derived : String)
  deriving Repr, DecidableEq

/-- Witness attached to one resolved field of a `RegexDraft`. The
    `address` is whatever the resolver substituted into the draft;
    `status` carries the strongest claim the daemon could make about
    that address at the moment of resolution. -/
structure Witness where
  /-- Field key in the regex draft: "to", "from", "spender", … -/
  key     : String
  address : String
  status  : Status
  deriving Repr

namespace Witness

def isVerified (w : Witness) : Bool :=
  match w.status with
  | .verified _ => true
  | _           => false

/-- Render the status as a short string for JSON / logging. The TUI
    parses these tags to pick a badge color. -/
def statusTag (w : Witness) : String :=
  match w.status with
  | .verified _   => "verified"
  | .locked       => "locked"
  | .hardware     => "hardware"
  | .book         => "book"
  | .external     => "external"
  | .mismatch _   => "mismatch"

/-- Extract the BIP-44 path (only `.verified` carries one). -/
def derivationPath? (w : Witness) : Option String :=
  match w.status with
  | .verified p => some p
  | _           => none

/-- For `.mismatch`, the address the resolver re-derived. -/
def derivedAddress? (w : Witness) : Option String :=
  match w.status with
  | .mismatch a => some a
  | _           => none

end Witness

end LeanCli.Ethereum.Ownership
