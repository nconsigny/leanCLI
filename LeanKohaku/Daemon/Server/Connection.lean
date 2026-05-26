import LeanKohaku.Daemon.Server.Core
import LeanKohaku.Crypto.Hacl
import LeanKohaku.Crypto.Secp256k1Native
import LeanKohaku.Daemon.Uds

/-!
# Daemon server: connection plumbing

Pure socket/boot/runtime-check helpers — none of which depend on the
RPC dispatch or any per-family module. Lifted out of Server.lean to
keep `Server.lean` itself down to just the router + per-connection
wiring + main entry point.

Contents:
  Socket teardown:      removeSocketFile, socketActivated, exitSoon
  Boot:                 ensureParentDir, listenerFromSocketActivation?,
                         decodeRequestBytes, detectExistingDaemon
  Native-helper precheck: requiredNativeHelpers, locateHelper,
                          verifyNativeHelpersOrExit
-/

namespace LeanKohaku.Daemon.Server

def removeSocketFile (socketPath : String) : IO Unit := do
  try
    IO.FS.removeFile socketPath
  catch _ =>
    pure ()

def socketActivated : IO Bool := do
  match ← IO.getEnv "LISTEN_FDS" with
  | some "1" => pure true
  | _ => pure false

def exitSoon (socketPath : String) : IO Unit := do
  IO.sleep 50
  unless (← socketActivated) do
    removeSocketFile socketPath
  IO.Process.exit 0

def ensureParentDir (socketPath : String) : IO Unit := do
  let path : System.FilePath := socketPath
  match path.parent with
  | some parent => IO.FS.createDirAll parent
  | none => pure ()

def listenerFromSocketActivation? : IO (Option LeanKohaku.Daemon.Uds.Listener) := do
  if ← socketActivated then
    pure (some { fd := 3 })
  else
    pure none

def decodeRequestBytes (bytes : ByteArray) : Except String String :=
  match String.fromUTF8? bytes with
  | some s => .ok s.trimAscii.toString
  | none => .error "request was not valid UTF-8"

def detectExistingDaemon (path : String) : IO (Option String) := do
  -- Try to connect. A successful connect means *some* listener is bound.
  let connAttempt ← IO.asTask (LeanKohaku.Daemon.Uds.connect path)
  -- We don't want to block forever on a wedged accept(); 250 ms cap.
  let connResult ← (do
    let mut waited : Nat := 0
    let step : Nat := 25
    let cap : Nat := 250
    let mut done : Option (Except IO.Error LeanKohaku.Daemon.Uds.Conn) := none
    while waited < cap && done.isNone do
      match ← IO.getTaskState connAttempt with
      | .finished =>
          done := some connAttempt.get
      | _ =>
          IO.sleep step.toUInt32
          waited := waited + step
    pure done)
  match connResult with
  | none =>
      -- connect() still pending after 250 ms — assume something is bound but
      -- wedged; refuse to start a second instance rather than racing.
      pure (some "already running (probe timed out)")
  | some (.error _) =>
      -- ECONNREFUSED / ENOENT both surface as IO errors here. Distinguish via
      -- the filesystem: if the path exists, the file is a stale leftover.
      let fp : System.FilePath := path
      if ← fp.pathExists then
        IO.eprintln s!"leankohaku-daemon: removed stale socket {path}"
        try IO.FS.removeFile path catch _ => pure ()
      pure none
  | some (.ok conn) =>
      -- Live listener accepted us. Send a daemon.ping and look for any reply,
      -- but don't block startup if the peer is slow — receiving the connect()
      -- alone is already proof of a competing daemon.
      let pingFrame :=
        "{\"jsonrpc\":\"2.0\",\"method\":\"daemon.ping\",\"params\":[],\"id\":1}\n"
      try
        discard <| LeanKohaku.Daemon.Uds.write conn pingFrame.toByteArray
      catch _ => pure ()
      let readTask ← IO.asTask (LeanKohaku.Daemon.Uds.read conn)
      let mut waited : Nat := 0
      let step : Nat := 25
      let cap : Nat := 250
      while waited < cap do
        match ← IO.getTaskState readTask with
        | .finished => waited := cap
        | _ =>
            IO.sleep step.toUInt32
            waited := waited + step
      try LeanKohaku.Daemon.Uds.close conn catch _ => pure ()
      pure (some "already running")

/-- Native helper binaries the daemon shells out to for every wallet op
    (PBKDF2 / HMAC / ChaCha20-Poly1305 / Keccak / secp256k1 sign+recover).
    They are produced by `script/setup_hacl.sh` and
    `script/setup_secp256k1.sh`, NOT by `lake build`, so a tree built
    with `lake build` alone is missing them and every unlock fails with
    a generic `could not execute external process` mid-flow. The boot
    precheck below stats each and refuses to listen if any are absent. -/
def requiredNativeHelpers : Array String := #[
  LeanKohaku.Crypto.Hacl.helperKeccak,
  LeanKohaku.Crypto.Hacl.helperSha256,
  LeanKohaku.Crypto.Hacl.helperHmacSha256,
  LeanKohaku.Crypto.Hacl.helperHmacSha512,
  LeanKohaku.Crypto.Hacl.helperRipemd160,
  LeanKohaku.Crypto.Hacl.helperPbkdf2,
  LeanKohaku.Crypto.Hacl.helperHmacDrbg,
  LeanKohaku.Crypto.Hacl.helperChacha20Poly1305,
  LeanKohaku.Crypto.Secp256k1Native.helperSign,
  LeanKohaku.Crypto.Secp256k1Native.helperPubkey,
  LeanKohaku.Crypto.Secp256k1Native.helperRecover,
  LeanKohaku.Crypto.Secp256k1Native.helperVerify
]

/-- Resolve a helper basename the same way `runHexHelper` does at run
    time: prefer `IO.appDir / cmd` (so a daemon shipped via kohakuspawn
    symlinks resolves through `/proc/self/exe`), fall back to a `$PATH`
    lookup. Returns the absolute path when found. -/
def locateHelper (cmd : String) : IO (Option String) := do
  let appDirHit ← try
    let next := (← IO.appDir) / cmd
    if ← next.pathExists then pure (some next.toString) else pure none
  catch _ => pure none
  match appDirHit with
  | some p => pure (some p)
  | none =>
      -- Fall back to $PATH. `IO.Process.output` with `cmd := basename`
      -- would do the lookup itself but we want to detect absence here.
      match ← IO.getEnv "PATH" with
      | none => pure none
      | some pathStr =>
          let dirs := pathStr.splitOn ":"
          let rec scan : List String → IO (Option String)
            | [] => pure none
            | d :: rest => do
                if d.isEmpty then scan rest
                else
                  let candidate := (System.FilePath.mk d) / cmd
                  if ← candidate.pathExists then pure (some candidate.toString)
                  else scan rest
          scan dirs

/-- Boot-time precheck. Lists every missing native helper, prints one
    actionable block to stderr naming the recovery command, and exits
    with code 70 (EX_SOFTWARE) — distinct from the second-instance exit
    (code 0) so systemd / kohakuspawn can tell the cases apart.

    The check runs after the second-instance guard so a healthy peer
    can keep serving even on a tree whose helpers were just nuked.

    Escape hatch: `KOHAKU_SKIP_HELPER_CHECK=1` downgrades to a single
    warning line. Intended for CI / smoke tests that exercise non-crypto
    code paths (locked-seed replies, RPC framing) on hosts that don't
    build the helpers. Never set this for an interactive daemon. -/
def verifyNativeHelpersOrExit : IO Unit := do
  let mut missing : Array String := #[]
  for cmd in requiredNativeHelpers do
    match ← locateHelper cmd with
    | some _ => pure ()
    | none   => missing := missing.push cmd
  if missing.isEmpty then return ()
  match ← IO.getEnv "KOHAKU_SKIP_HELPER_CHECK" with
  | some "1" | some "true" | some "yes" =>
      IO.eprintln
        s!"leankohaku-daemon: KOHAKU_SKIP_HELPER_CHECK=1 — \
          continuing despite {missing.size} missing native helper(s); \
          signing/unlock will fail at use time"
      return ()
  | _ => pure ()
  let appDir ← try
    let d ← IO.appDir
    pure d.toString
  catch _ => pure "(unknown)"
  IO.eprintln "leankohaku-daemon: missing native crypto helpers — refusing to start."
  IO.eprintln ""
  IO.eprintln s!"  Expected directory: {appDir}"
  IO.eprintln "  Missing binaries:"
  for cmd in missing do
    IO.eprintln s!"    - {cmd}"
  IO.eprintln ""
  IO.eprintln "  These are NOT produced by `lake build`. Build them with one of:"
  IO.eprintln "    lake script run setup-helpers      # recommended"
  IO.eprintln "    bash script/setup_hacl.sh && bash script/setup_secp256k1.sh"
  IO.eprintln "    kohakuspawn --rebuild-helpers      # if installed via kohakuspawn"
  IO.eprintln ""
  IO.eprintln "  Required system tools: git cmake ninja gcc cargo"
  IO.Process.exit 70

end LeanKohaku.Daemon.Server
