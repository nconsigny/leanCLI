/-!
# Sidecar spawn sandbox

Wraps every sidecar `IO.Process.spawn` with `unshare(1)` (Linux,
util-linux) when available. The bridges `Privacy/`, `Clearsign/`, and
`LlmAgent/` go through `Util.Sandbox.wrap` instead of building their
spawn args directly.

## Threat model and scope

Per the project trust model, every sidecar is treated as malicious. The
Lean daemon never signs on a sidecar's say-so; the simulate +
ConfirmGate stays the load-bearing safety net. This module narrows
*how much damage* a compromised sidecar can do at the OS level:

* **PID namespace** (`--pid --fork --mount-proc`): the sidecar cannot
  see, signal, or `ptrace` other processes on the host. A
  prompt-injected sidecar can no longer enumerate the daemon's pid or
  inject into a sibling process.
* **UTS/IPC namespaces** (`--uts --ipc`): no hostname tinkering, no
  System V IPC interaction with the host.
* **Network namespace** (`--net`): non-LLM sidecars get a fresh empty
  netns — no `lo`, no routes, no path to the internet or to localhost
  HTTP services. Their only outbound channel is the daemon UDS path
  (file-system, not net), which still works because UDS is namespace-
  agnostic at the filesystem level.

  The LLM bridge (`bridge/llm/`) keeps the host network namespace
  because it must talk to the local llama-server at `127.0.0.1:8080`.
  The loopback-only URL guard (in `bridge/llm/src/clients/`) is the
  enforcement layer there.

## What this slice does NOT do

* No filesystem isolation. Sidecars still see the full host fs.
  Adding `bwrap --ro-bind` would require tracking each sidecar's
  bridgeDir + `node_modules` location; deferred to a follow-up slice
  to avoid breaking the build on dev hosts.
* No seccomp filter. Defer to a follow-up.
* No user namespace. The sidecar still runs as the daemon's UID.

## Modes

`LEAN_KOHAKU_SANDBOX` env var:

* `off`     — passthrough, no wrapping. Use only for debugging.
* `auto`    — (default) wrap with `unshare` if present; warn-and-skip
              if missing. Suitable for dev hosts on non-Linux.
* `require` — refuse to spawn the sidecar if `unshare` is missing.
              Use in production deployments to enforce the floor.

Reference: [[reference-vitalik-secure-llms]] ("Sandbox everything. Be
paranoid about what exploits and threats rest on the outside internet.")
-/

namespace LeanKohaku.Util.Sandbox

/-- Per-sidecar spawn specification. The fields the caller fills in are
the *unwrapped* command + args + env; `wrap` returns the wrapped form. -/
structure SidecarSpec where
  cmd  : String
  args : Array String
  /-- Whether the sidecar needs TCP to host loopback (currently only
  the LLM bridge talking to llama-server). Drives the `--net` flag. -/
  needsTcpLoopback : Bool := false
  deriving Repr

inductive Mode where
  | off
  | auto
  | require
  deriving Repr, DecidableEq

def parseMode : Option String → Mode
  | some "off"     => .off
  | some "require" => .require
  | _              => .auto

/-- Try a few well-known absolute paths for `unshare`, then fall back to
`env which`. Returns `none` if no candidate is executable. -/
def detectUnshare : IO (Option String) := do
  let candidates : Array String := #[
    "/usr/bin/unshare",
    "/usr/local/bin/unshare",
    "/bin/unshare",
    "/run/current-system/sw/bin/unshare"
  ]
  for c in candidates do
    if ← System.FilePath.pathExists c then
      return some c
  try
    let out ← IO.Process.output { cmd := "/usr/bin/env", args := #["which", "unshare"] }
    if out.exitCode == 0 then
      let path := out.stdout.trimAscii.toString
      if path.isEmpty then return none else return some path
    else return none
  catch _ => return none

/-- Build the `unshare` arg prefix. PID + UTS + IPC are always
unshared; the network namespace is unshared unless the sidecar needs
loopback TCP to host services. -/
private def unshareFlags (spec : SidecarSpec) : Array String :=
  let base : Array String := #["--pid", "--fork", "--mount-proc", "--uts", "--ipc"]
  if spec.needsTcpLoopback then base
  else base ++ #["--net"]

/-- Wrap a sidecar spawn for sandboxing. Returns the (cmd, args) to
hand to `IO.Process.spawn`. The caller's existing env / stdin / stdout
/ stderr handling is unchanged. -/
def wrap (spec : SidecarSpec) : IO (String × Array String) := do
  let mode := parseMode (← IO.getEnv "LEAN_KOHAKU_SANDBOX")
  match mode with
  | .off => pure (spec.cmd, spec.args)
  | _ =>
      match ← detectUnshare with
      | some unshare =>
          let pre   := unshareFlags spec
          let full  := pre ++ #["--", spec.cmd] ++ spec.args
          pure (unshare, full)
      | none =>
          match mode with
          | .require =>
              throw <| IO.userError
                "LEAN_KOHAKU_SANDBOX=require but `unshare` not found on PATH"
          | _ =>
              IO.eprintln s!"[sandbox] WARNING: unshare not found; spawning {spec.cmd} without sandbox (set LEAN_KOHAKU_SANDBOX=require to refuse)"
              pure (spec.cmd, spec.args)

end LeanKohaku.Util.Sandbox
