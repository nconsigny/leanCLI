import LeanCli.Encoding.Json
import LeanCli.Transport.Uds
import LeanCli.Util.BridgeResolve

/-!
# Daemon-managed persistent Helios client

Spawns the helios sidecar in `--listen <socket>` mode and holds a UDS
connection for the daemon's lifetime. Helios's cold-start pays a
consensus sync (multiple seconds on mainnet), so the persistent client
amortizes it across every read in the session, mirroring the strategy
used for `Colibri.Persistent`.

The wire protocol is newline-delimited JSON-RPC over UDS:

  → {"jsonrpc":"2.0","method":"eth.proxy","params":{...},"id":N}\n
  ← {"jsonrpc":"2.0","id":N,"result":...}\n

Trust posture is identical to the one-shot bridge: the sidecar is
**untrusted** for signing decisions. Its output renders as confirmation
copy and the Lean side re-decodes signed txs through the existing path.
The persistent-connection delta is that committee state is held across
calls, so a compromised process has a longer leverage window; mitigation
is the same as Colibri's (cycle on daemon restart, re-decode at signing
time, propagate transport deaths so the caller can respawn).

This module is the **only** place that spawns the helios sidecar in
`--listen` mode. The one-shot `LeanCli.Helios.Bridge.call` (--rpc)
remains for ad-hoc scripts but is not on the read path.
-/

namespace LeanCli.Helios.Persistent

open LeanCli.Encoding.Json
open LeanCli.Transport.Uds

/-- A live connection to the persistent helios sidecar plus the next
    request id. The line buffer holds bytes read past a newline so the
    next `recv` doesn't lose framing. Same shape as
    `Colibri.Persistent.Client`. -/
structure Client where
  conn   : Conn
  socket : String
  pidFd  : Option UInt32  -- reserved for future supervisory hooks
  nextId : IO.Ref Nat
  buf    : IO.Ref ByteArray

/-- Default executable name for the helios sidecar (when on PATH). -/
def defaultExecutable : String := "leancli-helios-bridge"

/-- Resolve via the shared `BridgeResolve` chain
    (env → cwd-walk → recorded-checkout → PATH fallback). Mirrors the
    Colibri resolver. -/
def resolveExecutable : IO String :=
  LeanCli.Util.BridgeResolve.resolveExecutable
    "LEANCLI_HELIOS_BRIDGE"
    ("sidecars" / "kohaku" / "helios" / "bridge.mjs")
    defaultExecutable

/-- Spawn the sidecar in --listen mode and connect to it. The caller is
    responsible for keeping the returned `Client` alive for the daemon's
    lifetime; closing it terminates the sidecar (it exits on EOF / SIGPIPE). -/
def start (socketPath : String) : IO Client := do
  let exe ← resolveExecutable
  -- Helios writes its on-disk cache (`code_<hash>`, `states_<chainId>/`,
  -- `sync_<chainId>_<block>/`) into the sidecar's CWD. Confine those to a
  -- dedicated directory so they don't litter the project root, mirroring
  -- the Colibri cache layout.
  let cacheDir : System.FilePath := (← IO.currentDir) / "cache" / "helios"
  IO.FS.createDirAll cacheDir
  let _child ← IO.Process.spawn {
    cmd := exe,
    args := #["--listen", socketPath],
    cwd := some cacheDir.toString,
    stdin := .null,
    stdout := .null,
    stderr := .inherit
  }
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
      throw (IO.userError s!"helios persistent: could not connect to {socketPath} after {tries} retries")
  | some conn =>
      let nextId ← IO.mkRef 1
      let buf ← IO.mkRef (ByteArray.empty)
      pure { conn, socket := socketPath, pidFd := none, nextId, buf }

/-- Read one newline-terminated frame from the connection, draining the
    held line buffer first. Returns the bytes BEFORE the newline. -/
private partial def recvLine (c : Client) : IO ByteArray := do
  let rec scan : IO ByteArray := do
    let buf ← c.buf.get
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
          throw (IO.userError "helios persistent: connection closed")
        c.buf.set (buf ++ chunk)
        scan
  scan

private def writeAll (c : Client) (bytes : ByteArray) : IO Unit := do
  let mut remaining := bytes
  while remaining.size > 0 do
    let n ← write c.conn remaining
    if n == 0 then
      throw (IO.userError "helios persistent: short write")
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

/-- Heuristic classifier over an `IO.Error.toString` payload. Same shape
    as `Colibri.Persistent.isTransportCrashMsg`. -/
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
  | .error e => Response.crash s!"helios returned non-JSON ({e}): {raw}"
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
            | _ => "helios error"
          let data := (ef.find? (fun (k, _) => k == "data")).map Prod.snd
          Response.err code msg data
      | _ =>
          match lookup "result" with
          | some j => Response.ok j
          | none => Response.crash s!"helios response missing result: {raw}"
  | .ok _ => Response.crash s!"helios response not a JSON object: {raw}"

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

end LeanCli.Helios.Persistent
