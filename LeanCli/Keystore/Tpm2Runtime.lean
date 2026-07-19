import LeanCli.Basic
import LeanCli.Keystore.Enclave
import LeanCli.Crypto.Hex
import LeanCli.Wallet.Account
import LeanCli.Encoding.Json

/-!
# Local TPM2 runtime primitives

This module is the narrow runtime boundary for Linux TPM2 operations. It does
not link TPM libraries or implement crypto outside Lean. Instead it executes
local `tpm2-tools` commands.

After the P-256/R1 account + signing path was removed from the core, this
module hosts only the *generic* TPM2 primitives shared by the surviving
custody surface — TPM-sealed master-key (KEK) custody in
`Keystore/MasterKey.lean`: tool discovery, device probing, PIN validation,
checked process execution, and filesystem hardening. The R1 key-creation and
digest-signing functions that previously lived here are gone.

User verification is bound to the TPM object itself: the PIN is set as the
`userwithauth` value at key/seal creation time and re-checked by the TPM on
every operation. Dictionary-attack protection (lockout after N consecutive
failures) is enforced by the TPM in hardware. PIN bytes never appear on
`argv`; callers route them through a chmod-600 temp file and pass
`-p file:<path>` to tpm2-tools.
-/

namespace LeanCli.Keystore.Tpm2Runtime

open LeanCli.Crypto.Hex
open LeanCli.Keystore.Enclave
open LeanCli.Wallet.Account
open LeanCli.Encoding.Json

/-- A side-channel for PIN / TPM lifecycle events. The daemon overrides
    this with a closure that writes JSON-RPC notification frames onto
    the active UDS connection so the CLI can render user-facing status
    updates before the final response arrives. The default is a stderr
    trace (kept off the daemon stdout) for direct, non-daemon invocations. -/
abbrev Notifier := String → Json → IO Unit

/-- Default notifier: write a one-line trace to stderr. The daemon
    replaces this with a UDS-backed notifier that emits JSON-RPC
    notifications to the connected CLI. We deliberately avoid stdout
    so daemon stdout stays free of biometric noise even without an
    override. -/
def stderrNotifier : Notifier := fun event params =>
  IO.eprintln s!"[leancli:event] {event} {compact params}"

/-- Minimum acceptable PIN length, in characters. Below this we reject
    the request before touching the TPM, so an obvious mistype doesn't
    burn a slot in the dictionary-attack counter. Single source of truth is
    `LeanCli.minPinLength` (in `LeanCli.Basic`) so the thin CLI can share it
    without importing this keystore module. -/
def minPinLength : Nat := LeanCli.minPinLength

def validPin (pin : String) : Bool :=
  decide (pin.length ≥ minPinLength)

def logStep (msg : String) : IO Unit :=
  IO.println s!"[leancli:tpm2] {msg}"

def deviceAvailable : BaseIO Bool := do
  let tpm0 ← ("/dev/tpm0" : System.FilePath).pathExists
  let tpmrm0 ← ("/dev/tpmrm0" : System.FilePath).pathExists
  pure (tpm0 || tpmrm0)

def keyNameCharAllowed (c : Char) : Bool :=
  if ('a' ≤ c ∧ c ≤ 'z') then true
  else if ('A' ≤ c ∧ c ≤ 'Z') then true
  else if ('0' ≤ c ∧ c ≤ '9') then true
  else decide (c = '-') || decide (c = '_')

def validKeyName (name : String) : Bool :=
  !name.isEmpty &&
    decide (name.length ≤ 64) &&
    name.toList.all keyNameCharAllowed

def toolAvailable (tool : String) : IO Bool := do
  try
    let out ← IO.Process.output { cmd := tool, args := #["--version"] }
    pure (out.exitCode == 0)
  catch _ =>
    pure false

partial def firstMissingTool : List String → IO (Option String)
  | [] => pure none
  | tool :: rest => do
      if ← toolAvailable tool then
        firstMissingTool rest
      else
        pure (some tool)

partial def firstMissingToolLogged : List String → IO (Option String)
  | [] => pure none
  | tool :: rest => do
      logStep s!"checking tool: {tool}"
      if ← toolAvailable tool then
        logStep s!"tool available: {tool}"
        firstMissingToolLogged rest
      else
        logStep s!"tool missing: {tool}"
        pure (some tool)

def runChecked (cmd : String) (args : Array String) : IO (Except String String) := do
  try
    let out ← IO.Process.output { cmd := cmd, args := args }
    if out.exitCode == 0 then
      pure (.ok out.stdout)
    else
      pure (.error out.stderr)
  catch e =>
    pure (.error e.toString)

def chmodPath (mode : String) (path : System.FilePath) : IO Unit := do
  let _ ← IO.Process.output { cmd := "chmod", args := #[mode, path.toString] }
  pure ()

def hardenDir (path : System.FilePath) : IO Unit :=
  chmodPath "700" path

def hardenFile (path : System.FilePath) : IO Unit :=
  chmodPath "600" path

def fileArg (path : System.FilePath) : String :=
  path.toString

end LeanCli.Keystore.Tpm2Runtime
