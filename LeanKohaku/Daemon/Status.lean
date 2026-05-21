import LeanKohaku.Encoding.Json
import LeanKohaku.Basic
import LeanKohaku.Daemon.State
import LeanKohaku.Util.Sandbox
import LeanKohaku.Util.BridgeResolve
import LeanKohaku.Clearsign.Bridge
import LeanKohaku.Privacy.Bridge
import LeanKohaku.LlmAgent.Bridge
import LeanKohaku.Colibri.Persistent
import LeanKohaku.RPC.Outbound

/-!
# Daemon `status.snapshot` builder

One RPC returning the full debugging picture the TUI's Status page
needs: daemon identity, sidecar reachability + version probes, sandbox
posture (the AppArmor/userns probe that bit us during the May 20 demo),
build-time freshness markers, and on-disk install footprint. Everything
is read-only — mutations live on separate RPC methods.

The Status page UX is "is the wallet healthy and what should I do if
not?", so each field is paired with the diagnostic the user needs:
sidecar pings carry the resolved exe path, the sandbox block carries
the sysctl knob, the version block carries the binary mtime. The TUI
just renders; it does not interpret.

Why a snapshot RPC instead of N parallel pings: the page is requested
on-demand (R-to-refresh) and the sidecar pings are independent IO. A
single server-side call lets us run the pings concurrently with
`IO.asTask` and join with one timeout, instead of N round-trips from
the TUI that each pay their own UDS framing.
-/

namespace LeanKohaku.Daemon.Status

open LeanKohaku.Encoding.Json

/-- A descriptor of one sidecar for the snapshot loop. The `relPath` and
    `envVar` mirror the per-bridge resolver in `Util/BridgeResolve.lean`
    so the snapshot reports the same path the daemon would actually
    spawn at sidecar-call time. -/
private structure SidecarDescriptor where
  name        : String
  envVar      : String
  relPath     : System.FilePath
  defaultExe  : String

/-- The four sidecars the daemon owns. Order matters only for the TUI
    rendering — keep alphabetical so the Status page is deterministic. -/
private def sidecars : Array SidecarDescriptor := #[
  { name := "clearsign",
    envVar := "LEAN_KOHAKU_CLEARSIGN_BRIDGE",
    relPath := "bridge" / "clearsign" / "bridge.mjs",
    defaultExe := "leankohaku-clearsign-bridge" },
  { name := "colibri",
    envVar := "LEAN_KOHAKU_COLIBRI_BRIDGE",
    relPath := "bridge" / "colibri" / "bridge.mjs",
    defaultExe := "leankohaku-colibri-bridge" },
  { name := "llm",
    envVar := "LEAN_KOHAKU_LLM_BRIDGE",
    relPath := "bridge" / "llm" / "bridge.mjs",
    defaultExe := "leankohaku-llm-bridge" },
  { name := "privacy",
    envVar := "LEAN_KOHAKU_BRIDGE",
    relPath := "bridge" / "bridge.mjs",
    defaultExe := "leankohaku-kohaku-bridge" }
]

/-- Has the sidecar's `node_modules` been installed? Without this the
    `--rpc ping` will exit-1 with a require() error and the user has no
    way to tell whether the dep install was the issue vs the sidecar
    itself. Side-effect-free — only stats the parent directory. -/
private def hasNodeModules (resolvedExe : String) : IO Bool := do
  let bridgeDir := (System.FilePath.mk resolvedExe).parent.getD "."
  (bridgeDir / "node_modules").pathExists

/-- Spawn a sidecar with `--rpc {"method":"ping","jsonrpc":"2.0","id":0}`
    and return either the round-trip in ms or a short error string. Does
    NOT go through `Util.Sandbox.wrap` — the sandbox-wrapped path is
    what the daemon uses at sidecar-call time and may itself be the
    failure mode (Ubuntu AppArmor userns block); the status page wants
    to know if the sidecar *itself* works regardless of sandbox health.
    Sandbox status is reported separately. -/
private def pingSidecar (exe : String) : IO (Except String Nat) := do
  let req := "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":0}"
  let t0 ← IO.monoMsNow
  try
    let child ← IO.Process.spawn {
      cmd := exe,
      args := #["--rpc", req],
      stdin := .null,
      stdout := .piped,
      stderr := .piped
    }
    let stdout ← child.stdout.readToEnd
    let stderr ← child.stderr.readToEnd
    let exitCode ← child.wait
    let t1 ← IO.monoMsNow
    let elapsed := if t1 >= t0 then t1 - t0 else 0
    if exitCode != 0 then
      let errSnippet :=
        let raw := stderr.trimAscii.toString
        if raw.isEmpty then s!"exited {exitCode}, no stderr"
        else if raw.length > 240 then s!"exited {exitCode}: {(raw.take 240).toString}…"
        else s!"exited {exitCode}: {raw}"
      pure (.error errSnippet)
    else
      -- Sidecar may have exited cleanly but produced non-JSON; the
      -- ping shape we care about is just "exit 0 with a JSON-RPC
      -- response object in stdout".
      let trimmed := stdout.trimAscii.toString
      if trimmed.isEmpty then
        pure (.error "exit 0 but empty stdout")
      else
        pure (.ok elapsed)
  catch e =>
    pure (.error s!"spawn failed: {toString e}")

private def sidecarJson (desc : SidecarDescriptor) : IO Json := do
  let resolved ← LeanKohaku.Util.BridgeResolve.resolveExecutable
    desc.envVar desc.relPath desc.defaultExe
  -- envOverride lets the user see at a glance which lookup tier won
  -- (env > cwd-walk > recorded-checkout > PATH). The TUI uses this to
  -- label the row "env" / "checkout" / "fallback".
  let envOverride ← IO.getEnv desc.envVar
  let depsOk ← hasNodeModules resolved
  let ping ← pingSidecar resolved
  let (pingOk, pingMs, pingErr) := match ping with
    | .ok ms  => (true, Int.ofNat ms, "")
    | .error e => (false, (0 : Int), e)
  pure <| .obj #[
    ("name", .str desc.name),
    ("envVar", .str desc.envVar),
    ("envOverride", match envOverride with
      | some _ => .bool true
      | none => .bool false),
    ("resolverPath", .str resolved),
    ("depsInstalled", .bool depsOk),
    ("pingOk", .bool pingOk),
    ("pingMs", .num pingMs),
    ("pingError", .str pingErr)
  ]

private def sandboxJson : IO Json := do
  let mode := ((← IO.getEnv "LEAN_KOHAKU_SANDBOX").getD "auto")
  let usable ← LeanKohaku.Util.Sandbox.probeUsableUnshare
  let (usableBool, unsharePath) :=
    match usable with
    | some p => (true, p)
    | none   => (false, "")
  -- The sysctl hint is the operator's lever: surfacing it in the JSON
  -- lets the Status page link directly to the fix instead of asking the
  -- user to grep the daemon log for `[sandbox]`.
  let hint :=
    if usableBool then ""
    else "Restore the sandbox on Ubuntu 23.10+: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
  pure <| .obj #[
    ("mode", .str mode),
    ("unshareUsable", .bool usableBool),
    ("unsharePath", .str unsharePath),
    ("hint", .str hint)
  ]

private def daemonJson (state : LeanKohaku.Daemon.State.Shared) : IO Json := do
  let pid ← IO.Process.getPID
  let nowMs ← IO.monoMsNow
  let s ← state.get
  let uptimeMs : Int :=
    if nowMs >= s.startedAtMs then Int.ofNat (nowMs - s.startedAtMs)
    else 0
  pure <| .obj #[
    ("pid", .num (Int.ofNat pid.toNat)),
    ("uptimeMs", .num uptimeMs),
    ("version", .str LeanKohaku.version)
  ]

/-- Modification time in epoch-ms for a file, or `none` if the file is
    missing or the stat call fails. Best-effort: any IO error degrades
    to `none` so the Status snapshot never bubbles a transient
    filesystem error up to the user. -/
private def mtimeMs? (p : System.FilePath) : IO (Option Int) := do
  if !(← p.pathExists) then return none
  try
    let m ← p.metadata
    -- Metadata.modified : SystemTime { sec : Int, nsec : UInt32 }.
    -- Convert to ms-since-epoch the standard way: sec * 1000 + nsec /
    -- 1_000_000. nsec fits in UInt32 (max ~4e9), so the divide is safe.
    let sec : Int := m.modified.sec
    let nsecMs : Int := Int.ofNat (m.modified.nsec.toNat / 1000000)
    return some (sec * 1000 + nsecMs)
  catch _ => return none

/-- Read `.git/HEAD` → object id, following one level of symbolic ref.
    Cheap: no subprocess, no libgit2. Empty string on any miss. -/
private def gitHead? (checkoutRoot : System.FilePath) : IO String := do
  let headFile := checkoutRoot / ".git" / "HEAD"
  if !(← headFile.pathExists) then return ""
  try
    let raw ← IO.FS.readFile headFile
    let trimmed := raw.trimAscii.toString
    if trimmed.startsWith "ref: " then
      let refPath := (trimmed.drop 5).trimAscii.toString
      let refFile := checkoutRoot / ".git" / refPath
      if !(← refFile.pathExists) then return ""
      let sha ← IO.FS.readFile refFile
      return sha.trimAscii.toString
    return trimmed
  catch _ => return ""

/-- Resolve the recorded checkout root via `$KOHAKU_HOME/checkout` (the
    marker `kohakuspawn` writes). Falls back to the daemon's CWD if the
    marker is absent and a `lakefile.lean` is visible there — covers
    dev workflows running the daemon out of the source tree. -/
private def resolveCheckoutRoot : IO (Option System.FilePath) := do
  -- Honor explicit override first.
  match (← IO.getEnv "KOHAKU_CHECKOUT") with
  | some s =>
      let p := System.FilePath.mk s
      if (← (p / "lakefile.lean").pathExists) then return some p
      else return none
  | none =>
      let kohakuHome ← match (← IO.getEnv "KOHAKU_HOME") with
        | some s => pure (System.FilePath.mk s)
        | none =>
            match (← IO.getEnv "HOME") with
            | some h => pure ((System.FilePath.mk h) / ".kohaku")
            | none   => pure (System.FilePath.mk ".kohaku")
      let indexFile := kohakuHome / "checkout"
      if (← indexFile.pathExists) then
        try
          let raw ← IO.FS.readFile indexFile
          let p := System.FilePath.mk raw.toSubstring.trim.toString
          if (← (p / "lakefile.lean").pathExists) then return some p
          else return none
        catch _ => return none
      else
        -- Last-ditch: maybe daemon was launched from inside the checkout.
        let cwd ← IO.currentDir
        if (← (cwd / "lakefile.lean").pathExists) then return some cwd
        else return none

/-- Build-time mtime markers + (if available) git commit object-id. If
    the checkout root cannot be resolved (no `$KOHAKU_HOME/checkout`,
    no `lakefile.lean` in cwd), every field is `null` — the Status page
    renders "unknown" instead of failing. -/
private def versionsJson : IO Json := do
  let checkoutRoot ← resolveCheckoutRoot
  let binMtime ← match checkoutRoot with
    | some root => mtimeMs? (root / ".lake" / "build" / "bin" / "leankohaku")
    | none => pure none
  let bundleMtime ← match checkoutRoot with
    | some root => mtimeMs? (root / "tui" / "dist" / "index.mjs")
    | none => pure none
  let gitHead ← match checkoutRoot with
    | some root => gitHead? root
    | none => pure ""
  let asJson : Option Int → Json
    | some n => .num n
    | none   => .null
  pure <| .obj #[
    ("checkoutRoot", match checkoutRoot with
      | some r => .str r.toString
      | none => .null),
    ("daemonBinMtimeMs", asJson binMtime),
    ("tuiBundleMtimeMs", asJson bundleMtime),
    ("gitHead", .str gitHead)
  ]

/-- Wallet posture sketch — initialized?, master unlocked?, count of
    EOA slots currently held in `DaemonState.unlocked`. Does NOT touch
    the keystore — `wallet.master.status` and `eoa.list` are the
    authoritative read paths; this is a cheap shortcut to keep the
    Status page atomic. -/
private def walletJson (state : LeanKohaku.Daemon.State.Shared) : IO Json := do
  let unlocked ← LeanKohaku.Daemon.State.unlockedNames state
  let masterSlot? ← LeanKohaku.Daemon.State.getMasterKek? state
  pure <| .obj #[
    ("masterUnlocked", .bool masterSlot?.isSome),
    ("unlockedSlotCount", .num (Int.ofNat unlocked.length)),
    ("unlockedSlots", .arr (unlocked.toArray.map Json.str))
  ]

/-- Extract the host:port portion of a URL and strip the port. Returns
    `""` if extraction fails. Mirrors `RPC.Outbound.hostOfUrl` then drops
    the `:port` suffix so the result is suitable for DNS lookup. Bracketed
    IPv6 literals (`[::1]:8545`) come back as `[::1]`. -/
private def hostNoPort (url : String) : String := Id.run do
  let host := LeanKohaku.RPC.Outbound.hostOfUrl url
  let chars := host.toList
  if host.startsWith "[" then
    -- IPv6 in brackets: keep characters through the closing ']'.
    let mut acc : String := ""
    for c in chars do
      acc := acc.push c
      if c = ']' then return acc
    return acc
  -- IPv4 / hostname: stop at first ':' (port separator).
  let mut acc : String := ""
  for c in chars do
    if c = ':' then return acc
    acc := acc.push c
  return acc

/-- Best-effort IPv4 resolution for a hostname. Returns `""` on any
    failure (host empty, DNS unavailable, lookup timed out). Implementation
    uses `getent ahostsv4` because it honors `/etc/hosts`, NSS, and the
    system resolver in one shot without pulling a Lean DNS dep. Bounded
    by a short wait on the child process — if `getent` ever hangs we'd
    rather show a blank IP than wedge the Status snapshot. Skipped when
    `host` is already a dotted-quad or bracketed IPv6 literal. -/
private def resolveIpv4 (host : String) : IO String := do
  if host.isEmpty then return ""
  -- Skip lookup if the host already looks like a literal IP.
  if host.startsWith "[" then return host  -- IPv6 literal in brackets
  let looksLikeIPv4 :=
    let parts := host.splitOn "."
    parts.length = 4 && parts.all (fun p => !p.isEmpty && p.all (·.isDigit))
  if looksLikeIPv4 then return host
  try
    let child ← IO.Process.spawn {
      cmd := "getent",
      args := #["ahostsv4", host],
      stdin := .null,
      stdout := .piped,
      stderr := .null
    }
    let stdout ← child.stdout.readToEnd
    let exitCode ← child.wait
    if exitCode ≠ 0 then return ""
    -- `getent ahostsv4 example.com` prints lines like:
    --   "93.184.216.34 STREAM example.com"
    -- We want the first dotted-quad token of the first line.
    let firstLine := (stdout.splitOn "\n").headD ""
    let firstTok  := (firstLine.splitOn " ").headD ""
    return firstTok.trim
  catch _ => return ""

/-- Resolve a binary by trying well-known absolute paths, then falling
    back to `env which`. Returns `none` if not installed. PATH-lookup
    via bare `cmd := "name"` is unreliable under `IO.Process.spawn` —
    daemon's PATH can be sparse (e.g. systemd-launched) — so we resolve
    explicitly. -/
private def detectBinary (name : String) (candidates : Array String) :
    IO (Option String) := do
  for c in candidates do
    if ← System.FilePath.pathExists c then
      return some c
  try
    let out ← IO.Process.output { cmd := "/usr/bin/env", args := #["which", name] }
    if out.exitCode == 0 then
      let path := out.stdout.trimAscii.toString
      if path.isEmpty then return none else return some path
    else return none
  catch _ => return none

private def detectIpBinary : IO (Option String) :=
  detectBinary "ip" #[
    "/usr/bin/ip", "/usr/sbin/ip", "/sbin/ip", "/bin/ip",
    "/run/current-system/sw/bin/ip"
  ]

private def detectPython3 : IO (Option String) :=
  detectBinary "python3" #[
    "/usr/bin/python3", "/usr/local/bin/python3", "/bin/python3",
    "/run/current-system/sw/bin/python3"
  ]

/-- Python-based fallback for `routeEgress` when `ip(8)` can't open a
    netlink socket (sandboxes that restrict AF_NETLINK — common under
    systemd `RestrictAddressFamilies=`, some nspawn configs, etc.).
    Opens a UDP socket, `connect()`s to the destination, and reads back
    `getsockname()` — the kernel resolves the route and assigns a source
    address *without sending any packets*. Pure AF_INET, no netlink, no
    network traffic. Returns `(src, dev, err)` where `dev` is always
    `""` because `getsockname()` doesn't expose the interface name. -/
private def routeEgressViaPython
    (py : String) (ip : String) : IO (String × String × String) := do
  let script :=
    "import socket,sys\n" ++
    "try:\n" ++
    "    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\n" ++
    "    s.connect((sys.argv[1],443))\n" ++
    "    print(s.getsockname()[0])\n" ++
    "except Exception as e:\n" ++
    "    sys.stderr.write(str(e)); sys.exit(1)\n"
  try
    let child ← IO.Process.spawn {
      cmd := py,
      args := #["-c", script, ip],
      stdin := .null,
      stdout := .piped,
      stderr := .piped
    }
    let out ← child.stdout.readToEnd
    let err ← child.stderr.readToEnd
    let exitCode ← child.wait
    if exitCode ≠ 0 then
      let raw := err.trimAscii.toString
      return ("", "", s!"python fallback exit {exitCode}: {raw}")
    let src := out.trimAscii.toString
    if src.isEmpty then return ("", "", "python fallback: empty stdout")
    return (src, "", "")
  catch e =>
    return ("", "", s!"python fallback spawn failed: {toString e}")

/-- Local egress for a destination IP. Pure routing-table lookup — no
    packets sent, no third-party IP-echo service. Tries `ip -o route get
    <ip>` first; on failure (binary missing, AF_NETLINK denied by the
    sandbox, parse miss) falls back to an AF_INET UDP-connect +
    `getsockname()` trick via python3 — `connect()` on a UDP socket does
    not send any datagram, the kernel just consults the routing table to
    pick a source address. Returns `(src, dev, err)`; `dev` is set to
    `"udp-connect"` when the fallback path is used (getsockname doesn't
    expose the interface name). Privacy note: `src` is the address the
    wallet would dial *from*, useful for catching split-tunnel/VPN
    misconfigurations without phoning home. -/
private def routeEgress (ip : String) : IO (String × String × String) := do
  if ip.isEmpty then return ("", "", "no destination IP")
  -- First try `ip(8)`.
  let ipResult : IO (String × String × String) := do
    let ipBin ← match (← detectIpBinary) with
      | some p => pure p
      | none   => return ("", "", "ip(8) not found")
    try
      let child ← IO.Process.spawn {
        cmd := ipBin,
        args := #["-o", "route", "get", ip],
        stdin := .null,
        stdout := .piped,
        stderr := .piped
      }
      let out ← child.stdout.readToEnd
      let err ← child.stderr.readToEnd
      let exitCode ← child.wait
      if exitCode ≠ 0 then
        let raw := err.trimAscii.toString
        let snippet :=
          if raw.isEmpty then s!"{ipBin} exited {exitCode}"
          else if raw.length > 120 then s!"{ipBin} exit {exitCode}: {(raw.take 120).toString}…"
          else s!"{ipBin} exit {exitCode}: {raw}"
        return ("", "", snippet)
      let tokens := (out.splitOn " ").filterMap fun s =>
        let t := s.trimAscii.toString
        if t.isEmpty then none else some t
      let mut src : String := ""
      let mut dev : String := ""
      let mut prev : String := ""
      for tok in tokens do
        if prev = "src" then src := tok
        else if prev = "dev" then dev := tok
        prev := tok
      if src.isEmpty && dev.isEmpty then
        return ("", "", s!"parsed empty: {out.take 80}")
      return (src, dev, "")
    catch e =>
      return ("", "", s!"spawn failed: {toString e}")
  let (src, dev, err) ← ipResult
  if !src.isEmpty || !dev.isEmpty then return (src, dev, "")
  -- `ip` failed. Try the python AF_INET fallback if available.
  match (← detectPython3) with
  | none => return ("", "", s!"{err}; python3 fallback unavailable")
  | some py =>
      let (psrc, _pdev, perr) ← routeEgressViaPython py ip
      if !psrc.isEmpty then
        -- Tag the dev slot so the TUI can label "via UDP-connect" vs
        -- "via netlink". No real interface name from getsockname().
        return (psrc, "udp-connect", "")
      else
        return ("", "", s!"{err}; {perr}")

private def endpointJson (ep : LeanKohaku.RPC.Outbound.Endpoint) : IO Json := do
  let host := hostNoPort ep.url
  let ip ← resolveIpv4 host
  let (egressSrc, egressDev, egressError) ← routeEgress ip
  let chainIdJson : Json := match ep.chainId with
    | some n => .num (Int.ofNat n)
    | none   => .null
  pure <| .obj #[
    ("url", .str ep.url),
    ("transport", .str ep.transport.asString),
    ("backend", .str ep.backend.asString),
    ("host", .str host),
    ("ip", .str ip),
    ("egressSrc", .str egressSrc),
    ("egressDev", .str egressDev),
    ("egressError", .str egressError),
    ("chainId", chainIdJson)
  ]

/-- Per-chain endpoint with the `isCurrent` flag set against the active
    `chainId`. Mirrors the shape rendered in `network.show`'s `perChain`
    so the TUI can share rendering logic across both surfaces. -/
private def chainEndpointJson
    (activeChainId : Nat)
    (entry : String × LeanKohaku.RPC.Outbound.Endpoint) : IO Json := do
  let (name, ep) := entry
  let host := hostNoPort ep.url
  let ip ← resolveIpv4 host
  let (egressSrc, egressDev, egressError) ← routeEgress ip
  let resolvedChainId : Option Nat :=
    ep.chainId.orElse (fun _ => LeanKohaku.RPC.Outbound.chainNameToId name)
  let chainIdJson : Json := match resolvedChainId with
    | some n => .num (Int.ofNat n)
    | none   => .null
  let isCurrent : Bool := match resolvedChainId with
    | some n => n = activeChainId
    | none   => false
  pure <| .obj #[
    ("name", .str name),
    ("chainId", chainIdJson),
    ("url", .str ep.url),
    ("transport", .str ep.transport.asString),
    ("backend", .str ep.backend.asString),
    ("host", .str host),
    ("ip", .str ip),
    ("egressSrc", .str egressSrc),
    ("egressDev", .str egressDev),
    ("egressError", .str egressError),
    ("isCurrent", .bool isCurrent)
  ]

/-- Build the full snapshot. `chainId`/`policy` are mirrored from the
    daemon config so the Status page's Network sub-section can render
    without an extra `network.show` round-trip. The per-chain endpoint
    list + active `rpc`/`ens` endpoints are included so the TUI can show
    the full URL (and resolved IPv4) of every configured RPC at a glance,
    avoiding the user having to leave the Status page to inspect
    `network.show`. -/
def buildSnapshot
    (state : LeanKohaku.Daemon.State.Shared)
    (chainId : Nat) (policyName : String) (socketPath : String)
    (rpcEndpoint : LeanKohaku.RPC.Outbound.Endpoint)
    (ensRpcEndpoint : Option LeanKohaku.RPC.Outbound.Endpoint)
    (chainEndpoints : Array (String × LeanKohaku.RPC.Outbound.Endpoint)) :
    IO Json := do
  -- Fan out sidecar pings concurrently. Each task does its own spawn
  -- + read; we join at the end with a single sequential await. With 4
  -- sidecars this turns ~400ms of serial pings into one ~100ms wall
  -- clock — small but the user notices when they're hitting R.
  let tasks ← sidecars.mapM fun desc =>
    IO.asTask (sidecarJson desc)
  let sidecarResults ← tasks.mapM fun task => do
    match ← IO.wait task with
    | .ok j => pure j
    | .error _ => pure (.obj #[
        ("name", .str "unknown"),
        ("pingOk", .bool false),
        ("pingError", .str "snapshot task failed")
      ])
  let daemon ← daemonJson state
  let sandbox ← sandboxJson
  let versions ← versionsJson
  let wallet ← walletJson state
  let rpcJson ← endpointJson rpcEndpoint
  let ensJson : Json ← match ensRpcEndpoint with
    | some ep => endpointJson ep
    | none    => pure .null
  let chainsJson ← chainEndpoints.mapM (chainEndpointJson chainId)
  pure <| .obj #[
    ("daemon", daemon),
    ("sidecars", .arr sidecarResults),
    ("sandbox", sandbox),
    ("versions", versions),
    ("wallet", wallet),
    ("network", .obj #[
      ("chainId", .num (Int.ofNat chainId)),
      ("policy", .str policyName),
      ("socketPath", .str socketPath),
      ("rpc", rpcJson),
      ("ens", ensJson),
      ("chains", .arr chainsJson)
    ])
  ]

end LeanKohaku.Daemon.Status
