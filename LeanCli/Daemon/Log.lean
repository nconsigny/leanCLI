import LeanCli.Encoding.Json

/-!
# Daemon logging

JSON-line records to stderr. Keep records deliberately small; request params,
addresses, passphrases, and signatures are never logged here.
-/

namespace LeanCli.Daemon.Log

open LeanCli.Encoding.Json

inductive Level where
  | info
  | warn
  | error
  deriving Repr, DecidableEq

def Level.toString : Level → String
  | .info => "info"
  | .warn => "warn"
  | .error => "error"

def write (level : Level) (method : String) (latencyMs : Nat) (ok : Bool)
    (error? : Option String := none) : IO Unit := do
  let ts ← IO.monoMsNow
  let fields := #[
    ("ts", Json.num (Int.ofNat ts)),
    ("level", Json.str level.toString),
    ("method", Json.str method),
    ("latency_ms", Json.num (Int.ofNat latencyMs)),
    ("ok", Json.bool ok)
  ]
  let fields :=
    match error? with
    | none => fields
    | some err => fields.push ("error", Json.str err)
  IO.eprintln (compact (.obj fields))

end LeanCli.Daemon.Log
