/-!
# LeanCli

Formally-verified Ethereum wallet written entirely in Lean 4.

See `LeanCli.lean` for the top-level re-exports and `INVARIANTS.md`
for the list of properties we aim to prove.
-/

namespace LeanCli

def version : String := "0.1.0"

/-- Minimum acceptable TPM/master PIN length, in characters. Single source of
    truth shared by the daemon (which enforces it before touching the TPM, so
    an obvious mistype doesn't burn a dictionary-attack slot) and the thin CLI
    (which pre-validates interactive PIN entry). Lives in `LeanCli.Basic` — a
    foundational, isolation-safe module — so the CLI can reference it without
    importing `LeanCli.Keystore.*` (which the CLI-isolation guard forbids). -/
def minPinLength : Nat := 4

end LeanCli
