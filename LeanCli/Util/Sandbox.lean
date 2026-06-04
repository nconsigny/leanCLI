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

  The legacy LLM bridge (`bridge/llm-legacy/`, reachable via
  `LEANCLI_LLM_BRIDGE_LEGACY=1`) keeps the host network namespace
  because it must talk to the local llama-server at `127.0.0.1:8080`.
  The loopback-only URL guard (in `bridge/llm-legacy/src/clients/`) is
  the enforcement layer there. The Phase 0 default `leancli-agent`
  (Lean) does not need a Node sandbox carve-out because it is a
  trusted in-tree binary; its loopback enforcement lives in
  `c/lean_http/` + `LeanCli/Agent/Http.lean`.

## What this slice does NOT do

* No filesystem isolation. Sidecars still see the full host fs.
  Adding `bwrap --ro-bind` would require tracking each sidecar's
  bridgeDir + `node_modules` location; deferred to a follow-up slice
  to avoid breaking the build on dev hosts.
* No seccomp filter. Defer to a follow-up.
* User namespace is created (`--user --map-current-user`) so that
  unprivileged daemons can use the other namespaces without
  CAP_SYS_ADMIN. UID mapping is identity, so the sidecar still runs
  as the daemon's UID — no privilege gain inside the namespace.

## Modes

`LEANCLI_SANDBOX` env var:

* `off`     — passthrough, no wrapping. Use only for debugging.
* `auto`    — (default) wrap with `unshare` if it is present AND usable
              at runtime; warn-once-and-skip if missing or refused.
              Suitable for dev hosts on non-Linux *and* for Linux hosts
              where AppArmor / hardened-kernel policies forbid
              unprivileged user namespaces (Ubuntu 23.10+ default).
* `require` — refuse to spawn the sidecar if `unshare` is not usable.
              Use in production deployments to enforce the floor.

## Runtime probe (Ubuntu 23.10+ / AppArmor + nested-container caveat)

`auto` mode used to degrade only when `unshare(1)` was missing from
PATH. That left a silent-failure window on hosts where `unshare(1)` is
installed but the kernel refuses one of the flags we actually use.
Two real-world cases:

* `--user --map-current-user` refused —
  `kernel.apparmor_restrict_unprivileged_userns=1` (Ubuntu 23.10+
  default), `kernel.unprivileged_userns_clone=0` (hardened kernels).
* `--mount-proc` refused — nested container runtimes
  (systemd-nspawn, rootless Docker/Podman, Flatpak/Snap, GitHub
  Actions container jobs) where the outer userns / mount policy
  forbids mounting a fresh procfs in a nested PID namespace.

In both cases every sidecar spawn returned exit-1 with empty stderr,
and the daemon surfaced `{ok:false, crash:...}` to the TUI without any
user-visible explanation of why.

The probe now exercises the *full base flag set* (`baseUnshareFlags`)
that real spawns will use, once per daemon process (cached in a ref).
If it exits non-zero, the rest of the session takes the warn-once-and-
skip path — same code path as "unshare not installed". The warning
names both failure modes so the operator can tell whether the sysctl
knob will help (Ubuntu) or whether the daemon needs to move off a
nested-container host.

Reference: [[reference-vitalik-secure-llms]] ("Sandbox everything. Be
paranoid about what exploits and threats rest on the outside internet.")
-/

namespace LeanCli.Util.Sandbox

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

/-- Cached result of the runtime usability probe. Three states:
    `none` = not probed yet; `some none` = probed, not usable;
    `some (some path)` = probed, usable at that path. -/
initialize usableUnshareRef : IO.Ref (Option (Option String)) ← IO.mkRef none

/-- Whether we've already printed the "sandbox disabled" warning to
    stderr. Keeps the auto-degrade path from spamming the daemon log
    once per sidecar spawn. -/
initialize sandboxWarnedRef : IO.Ref Bool ← IO.mkRef false

/-- Flags shared by every sandboxed spawn: user + PID + procfs + UTS +
IPC. The network namespace is added per-spec by `unshareFlags`. Kept as
a single source of truth so `probeUsableUnshare` exercises the *exact*
set that will be requested at spawn time. -/
private def baseUnshareFlags : Array String :=
  #["--user", "--map-current-user", "--pid", "--fork", "--mount-proc", "--uts", "--ipc"]

/-- Probe the full base flag set once and cache the result. Returns the
    path to a usable `unshare` binary, or `none` if `unshare(1)` is
    missing or any base flag is refused at runtime. Failure modes the
    probe must cover:

    * `--user --map-current-user` refused — AppArmor unprivileged-userns
      restriction on Ubuntu 23.10+, `kernel.unprivileged_userns_clone=0`
      on hardened kernels.
    * `--mount-proc` refused — nested container hosts (systemd-nspawn,
      rootless Docker/Podman, Flatpak/Snap, GitHub Actions container
      jobs) where the outer userns / mount policy forbids mounting a
      fresh procfs in a nested PID namespace.

    Probing only `--user --map-current-user` (as an earlier version did)
    lied on nested-container hosts: the probe said sandbox was usable,
    then every real sidecar spawn died with `unshare: mount /proc
    failed: Operation not permitted` and the daemon surfaced an opaque
    crash to the TUI. Exercising the full base set here makes the
    failure observable and routes it through the warn-once-and-degrade
    path the same way the Ubuntu AppArmor case is handled. -/
def probeUsableUnshare : IO (Option String) := do
  match ← usableUnshareRef.get with
  | some cached => pure cached
  | none =>
      let result ← do
        match ← detectUnshare with
        | none => pure none
        | some path =>
            try
              let child ← IO.Process.spawn {
                cmd := path,
                args := baseUnshareFlags ++ #["--", "true"],
                stdin := .null,
                stdout := .null,
                -- Probe noise (e.g. "unshare: write failed
                -- /proc/self/uid_map: Operation not permitted" or
                -- "unshare: mount /proc failed: Operation not
                -- permitted") would otherwise hit the daemon journal
                -- on every fresh boot. The diagnostic gets printed by
                -- `warnSandboxDisabled` below in user-friendly form
                -- instead.
                stderr := .null
              }
              let code ← child.wait
              pure (if code == 0 then some path else none)
            catch _ => pure none
      usableUnshareRef.set (some result)
      pure result

/-- Print the "sandbox disabled" warning once per process. Names the
    two common blocking host configs (Ubuntu 23.10+ AppArmor and
    nested-container runtimes) so the operator knows whether the
    sysctl knob will help. -/
private def warnSandboxDisabled (cmd : String) : IO Unit := do
  unless (← sandboxWarnedRef.get) do
    sandboxWarnedRef.set true
    IO.eprintln s!"[sandbox] WARNING: full unshare base set is not usable on this host (missing `unshare(1)`, AppArmor/kernel refusing unprivileged userns, or a nested container runtime — systemd-nspawn / rootless Docker / Podman / Flatpak / GitHub Actions — refusing `--mount-proc` in a nested PID namespace). Spawning {cmd} and subsequent sidecars without OS-level sandboxing. The cryptographic trust model is unchanged — the daemon still re-decodes every signed tx before broadcast — but a compromised sidecar has more reach at the OS level. Set LEANCLI_SANDBOX=require to fail-fast instead. To restore sandboxing on Ubuntu 23.10+: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 . Nested-container hosts have no equivalent knob — run the daemon on the bare host."

/-- Build the `unshare` arg prefix. PID + UTS + IPC + procfs are always
unshared; the network namespace is unshared unless the sidecar needs
loopback TCP to host services. `--user --map-current-user` is required
so an unprivileged daemon can unshare the other namespaces without
CAP_SYS_ADMIN; UID mapping is preserved so the sidecar still runs as
the daemon's UID inside the namespace. -/
private def unshareFlags (spec : SidecarSpec) : Array String :=
  if spec.needsTcpLoopback then baseUnshareFlags
  else baseUnshareFlags ++ #["--net"]

/-- Wrap a sidecar spawn for sandboxing. Returns the (cmd, args) to
hand to `IO.Process.spawn`. The caller's existing env / stdin / stdout
/ stderr handling is unchanged.

In `auto` mode, the wrap degrades to the unsandboxed spawn whenever
`probeUsableUnshare` returns `none` — i.e. when `unshare(1)` is
missing OR present-but-refused-at-runtime. The latter case (Ubuntu
23.10+ AppArmor restriction, hardened-kernel `unprivileged_userns_clone=0`)
used to manifest as silent sidecar exit-1; the probe + warn-once path
makes the failure mode observable and recoverable without an install-
time `LEANCLI_SANDBOX=off` override. -/
def wrap (spec : SidecarSpec) : IO (String × Array String) := do
  let mode := parseMode (← IO.getEnv "LEANCLI_SANDBOX")
  match mode with
  | .off => pure (spec.cmd, spec.args)
  | _ =>
      match ← probeUsableUnshare with
      | some unshare =>
          let pre   := unshareFlags spec
          let full  := pre ++ #["--", spec.cmd] ++ spec.args
          pure (unshare, full)
      | none =>
          match mode with
          | .require =>
              throw <| IO.userError
                "LEANCLI_SANDBOX=require but the unshare base flag set (user + pid + mount-proc + uts + ipc) is not usable on this host. Likely causes: (1) AppArmor unprivileged-userns restriction on Ubuntu 23.10+ — lift with: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 ; (2) nested-container runtime (systemd-nspawn / rootless Docker / Podman / Flatpak / GitHub Actions) refusing --mount-proc — no knob, run the daemon on the bare host."
          | _ =>
              warnSandboxDisabled spec.cmd
              pure (spec.cmd, spec.args)

end LeanCli.Util.Sandbox
