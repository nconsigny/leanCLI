import LeanCli.Encoding.Json
import LeanCli.Transport.Uds
import LeanCli.Util.BridgeResolve

/-!
# Daemon-managed persistent Colibri client

Spawns the colibri sidecar in `--listen <socket>` mode and holds a UDS
connection for the daemon's lifetime. Solves the cold-start problem the
one-shot `--rpc` path hits: each invocation in one-shot mode pays the
sync-committee bootstrap (multiple seconds), so wiring it into reads like
`eth_getBalance` is impractical. With the persistent client, bootstrap
runs once per chainId per daemon lifetime.

The wire protocol is newline-delimited JSON-RPC over UDS:

  → {"jsonrpc":"2.0","method":"eth.proxy","params":{...},"id":N}\n
  ← {"jsonrpc":"2.0","id":N,"result":...}\n

Trust posture is unchanged from the one-shot bridge: the sidecar is
**untrusted** for signing decisions; outputs render as confirmation copy
and the Lean side re-decodes signed txs through the existing path. The
delta is that a persistent client maintains committee state across calls,
so a compromised process has a longer leverage window. Mitigation: the
daemon re-checks every read result the same way it does today
(via re-decode at signing time), and the sidecar can be cycled by
restarting the daemon.

This module is the **only** place that spawns the sidecar in --listen
mode. The original `LeanCli.Colibri.Bridge.call` (--rpc one-shot) is
preserved for backward compatibility but should be considered legacy.
-/

namespace LeanCli.Colibri.Persistent

open LeanCli.Encoding.Json
open LeanCli.Transport.Uds

/-- A live connection to the persistent colibri sidecar plus the next
    request id. The line buffer holds bytes read past a newline so the
    next `recv` doesn't lose framing. -/
structure Client where
  conn   : Conn
  socket : String
  pidFd  : Option UInt32  -- reserved for future supervisory hooks
  nextId : IO.Ref Nat
  buf    : IO.Ref ByteArray

/-- Default executable name for the colibri sidecar (when on PATH). -/
def defaultExecutable : String := "leancli-colibri-bridge"

/-- Resolve via the shared `BridgeResolve` chain
    (env → cwd-walk → recorded-checkout → PATH fallback). The other three
    sidecar resolvers use the same chain — this is the template they were
    factored from. -/
def resolveExecutable : IO String :=
  LeanCli.Util.BridgeResolve.resolveExecutable
    "LEANCLI_COLIBRI_BRIDGE"
    ("sidecars" / "kohaku" / "colibri" / "bridge.mjs")
    defaultExecutable

/-- Spawn the sidecar in --listen mode and connect to it. The caller is
    responsible for keeping the returned `Client` alive for the daemon's
    lifetime; closing it terminates the sidecar (it exits on EOF / SIGPIPE). -/
def start (socketPath : String) : IO Client := do
  let exe ← resolveExecutable
  -- Helios writes its on-disk cache (`code_<hash>`, `states_<chainId>/`,
  -- `sync_<chainId>_<block>/`) into the sidecar's CWD. Confine those to a
  -- dedicated directory so they don't litter the project root.
  let cacheDir : System.FilePath := (← IO.currentDir) / "cache" / "colibri"
  IO.FS.createDirAll cacheDir
  -- Spawn the sidecar detached enough that it survives across daemon
  -- request handling but tied to our process group so it exits with us.
  let _child ← IO.Process.spawn {
    cmd := exe,
    args := #["--listen", socketPath],
    cwd := some cacheDir.toString,
    stdin := .null,
    stdout := .null,
    stderr := .inherit
  }
  -- Wait until the socket exists. Cold spawn typically settles in <100ms.
  let mut tries : Nat := 0
  let mut connected : Option Conn := none
  while connected.isNone && tries < 50 do
    try
      let c ← connect socketPath
      connected := some c
    catch _ =>
      IO.sleep 50
      tries := tries + 1
  match connected with
  | none =>
      throw (IO.userError s!"colibri persistent: could not connect to {socketPath} after {tries} retries")
  | some conn =>
      let nextId ← IO.mkRef 1
      let buf ← IO.mkRef (ByteArray.empty)
      pure { conn, socket := socketPath, pidFd := none, nextId, buf }

/-- Read one newline-terminated frame from the connection, draining the
    held line buffer first. Returns the bytes BEFORE the newline. -/
private partial def recvLine (c : Client) : IO ByteArray := do
  let rec scan : IO ByteArray := do
    let buf ← c.buf.get
    -- Look for '\n' in the buffer.
    let mut nlAt : Option Nat := none
    for i in [0 : buf.size] do
      if buf.get! i == 0x0A then
        nlAt := some i
        break
    match nlAt with
    | some idx =>
        let line := buf.extract 0 idx
        let rest := buf.extract (idx + 1) buf.size
        c.buf.set rest
        return line
    | none =>
        let chunk ← read c.conn 65536
        if chunk.size == 0 then
          throw (IO.userError "colibri persistent: connection closed")
        c.buf.set (buf ++ chunk)
        scan
  scan

private def writeAll (c : Client) (bytes : ByteArray) : IO Unit := do
  let mut remaining := bytes
  while remaining.size > 0 do
    let n ← write c.conn remaining
    if n == 0 then
      throw (IO.userError "colibri persistent: short write")
    remaining := remaining.extract n.toNat remaining.size

inductive Response where
  | ok    (result : Json)
  | err   (code : Int) (message : String) (data : Option Json)
  | crash (reason : String)
  /-- A transport-level failure on the persistent UDS conn: the sidecar
      died (broken pipe / SIGPIPE), the conn was closed under us, or a
      write returned 0. Distinct from `crash` so the daemon can decide to
      respawn-and-retry instead of propagating an opaque crash. -/
  | transportCrash (reason : String)
  deriving Repr

/-- Heuristic classifier over an `IO.Error.toString` payload. We keep this
    string-shaped (rather than pattern-matching on the error variant) because
    the runtime types in `IO.Error` are unstable across Lean versions; the
    actual recoverable cases all surface through `IO.userError` from this
    module (`writeAll` "short write", `recvLine` "connection closed") and
    through the Lean IO wrapper when libc reports EPIPE / ECONNRESET on a
    UDS write. -/
def isTransportCrashMsg (s : String) : Bool :=
  let s := s.toLower
  let contains (needle : String) : Bool :=
    (s.splitOn needle).length > 1
  contains "broken pipe"
    || contains "connection closed"
    || contains "connection reset"
    || contains "short write"
    || contains "epipe"
    || contains "econnreset"

private def parseResponse (raw : String) : Response :=
  match parse raw with
  | .error e => Response.crash s!"colibri returned non-JSON ({e}): {raw}"
  | .ok (Json.obj fields) =>
      let lookup (k : String) : Option Json :=
        (fields.find? (fun (key, _) => key == k)).map Prod.snd
      match lookup "error" with
      | some (Json.obj ef) =>
          let code := match (ef.find? (fun (k, _) => k == "code")).map Prod.snd with
            | some (Json.num n) => n
            | _ => -32603
          let msg := match (ef.find? (fun (k, _) => k == "message")).map Prod.snd with
            | some (Json.str s) => s
            | _ => "colibri error"
          let data := (ef.find? (fun (k, _) => k == "data")).map Prod.snd
          Response.err code msg data
      | _ =>
          match lookup "result" with
          | some j => Response.ok j
          | none => Response.crash s!"colibri response missing result: {raw}"
  | .ok _ => Response.crash s!"colibri response not a JSON object: {raw}"

/-- Send a request and synchronously read the matching response. Caller
    must serialize across threads (the daemon is single-threaded per
    socket, so a single Client is fine). -/
def call (c : Client) (method : String) (params : Json) : IO Response := do
  let id ← c.nextId.get
  c.nextId.set (id + 1)
  let payload : String := compact <| .obj #[
    ("jsonrpc", .str "2.0"),
    ("method",  .str method),
    ("params",  params),
    ("id",      .num (Int.ofNat id))
  ]
  let line := payload ++ "\n"
  try
    writeAll c line.toUTF8
    let respBytes ← recvLine c
    let respStr := String.fromUTF8! respBytes
    pure (parseResponse respStr)
  catch e =>
    let msg := e.toString
    if isTransportCrashMsg msg then
      pure (Response.transportCrash msg)
    else
      pure (Response.crash s!"transport error: {msg}")

/-- Render a `Response` as JSON for forwarding through the daemon's
    JSON-RPC surface. Mirrors `Bridge.responseToJson`. -/
def responseToJson : Response → Json
  | .ok j => .obj #[("ok", .bool true), ("result", j)]
  | .err code msg data =>
      .obj #[
        ("ok", .bool false),
        ("error", .obj <| #[
          ("code", .num code),
          ("message", .str msg)
        ] ++ (match data with
              | some d => #[("data", d)]
              | none => #[]))
      ]
  | .crash reason =>
      .obj #[
        ("ok", .bool false),
        ("crash", .obj #[("reason", .str reason)])
      ]
  | .transportCrash reason =>
      .obj #[
        ("ok", .bool false),
        ("crash", .obj #[("reason", .str reason), ("transport", .bool true)])
      ]

/-- Tear down the connection. The sidecar exits on the resulting EOF. -/
def close (c : Client) : IO Unit := do
  try shutdown c.conn catch _ => pure ()
  try LeanCli.Transport.Uds.close c.conn catch _ => pure ()

end LeanCli.Colibri.Persistent
