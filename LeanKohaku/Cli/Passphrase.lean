/-!
# CLI passphrase / PIN input

Small helper for commands that need a secret before forwarding the request
to the daemon. `LEANKOHAKU_PASSPHRASE` and `LEANKOHAKU_PIN` are accepted for
scripted tests; the interactive fallback disables terminal echo when possible.
-/

namespace LeanKohaku.Cli.Passphrase

private def runStty (arg : String) : IO Unit := do
  try
    let child ← IO.Process.spawn
      { cmd := "sh",
        args := #["-c", "stty " ++ arg ++ " < /dev/tty"],
        stdout := .inherit,
        stderr := .inherit }
    discard <| child.wait
  catch _ =>
    pure ()

private def prompt (label : String) : IO Unit := do
  (← IO.getStderr).putStr label
  (← IO.getStderr).flush

/-- Read a secret from the terminal with echo disabled, or pull it from the
    given env var when set. Used for both passphrases and PINs. -/
private def readSecret (envVar : String) (label : String) : IO String := do
  match ← IO.getEnv envVar with
  | some secret => pure secret
  | none =>
      prompt label
      runStty "-echo"
      try
        let line ← (← IO.getStdin).getLine
        (← IO.getStderr).putStrLn ""
        pure line.trimAsciiEnd.toString
      finally
        runStty "echo"

def read (label : String := "Passphrase: ") : IO String :=
  readSecret "LEANKOHAKU_PASSPHRASE" label

end LeanKohaku.Cli.Passphrase

namespace LeanKohaku.Cli.Pin

/-- Read a TPM PIN from the terminal with echo disabled. Falls back to the
    `LEANKOHAKU_PIN` env var when set, so scripted tests can drive the flow
    without poking the terminal. -/
def read (label : String := "PIN: ") : IO String := do
  match ← IO.getEnv "LEANKOHAKU_PIN" with
  | some pin => pure pin
  | none =>
      try
        let child ← IO.Process.spawn
          { cmd := "sh",
            args := #["-c", "stty -echo < /dev/tty"],
            stdout := .inherit,
            stderr := .inherit }
        discard <| child.wait
      catch _ => pure ()
      (← IO.getStderr).putStr label
      (← IO.getStderr).flush
      try
        let line ← (← IO.getStdin).getLine
        (← IO.getStderr).putStrLn ""
        pure line.trimAsciiEnd.toString
      finally
        try
          let child ← IO.Process.spawn
            { cmd := "sh",
              args := #["-c", "stty echo < /dev/tty"],
              stdout := .inherit,
              stderr := .inherit }
          discard <| child.wait
        catch _ => pure ()

/-- Read and confirm a fresh PIN (creation flow). Returns `.error` on
    mismatch or on PIN below `minLen` characters. -/
def readConfirmed (minLen : Nat) : IO (Except String String) := do
  let first ← read "New PIN: "
  if first.length < minLen then
    pure (.error s!"PIN must be at least {minLen} characters")
  else
    let again ← read "Confirm PIN: "
    if first = again then pure (.ok first)
    else pure (.error "PINs did not match")

end LeanKohaku.Cli.Pin
