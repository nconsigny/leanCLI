import LeanKohaku.Encoding.Json
import LeanKohaku.Transport.Uds

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
mode. The original `LeanKohaku.Colibri.Bridge.call` (--rpc one-shot) is
preserved for backward compatibility but should be considered legacy.
-/

namespace LeanKohaku.Colibri.Persistent

open LeanKohaku.Encoding.Json
open LeanKohaku.Transport.Uds

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
def defaultExecutable : String := "leankohaku-colibri-bridge"

/-- Walk upward from the working directory looking for the
    `bridge/colibri/bridge.mjs` script that ships in this repo. Returns
    the first match within `maxHops` parents, or `none`. Lets the daemon
    work out-of-the-box from anywhere inside the monorepo without an
    explicit `LEAN_KOHAKU_COLIBRI_BRIDGE` env var. -/
private partial def findBridgeMjs (start : System.FilePath) (maxHops : Nat) :
    IO (Option String) := do
  let candidate := start / "bridge" / "colibri" / "bridge.mjs"
  if (← candidate.pathExists) then
    pure (some candidate.toString)
  else
    match maxHops, start.parent with
    | 0, _ => pure none
    | _ + 1, none => pure none
    | n + 1, some parent =>
        if parent == start then pure none else findBridgeMjs parent n

/-- Read the recorded checkout path written by `script/kohakuspawn` to
    `$KOHAKU_HOME/checkout` (default `$HOME/.kohaku/checkout`). Returns
    the path to `bridge/colibri/bridge.mjs` inside that checkout if both
    the index file and the script exist. -/
private def findBridgeViaRecordedCheckout : IO (Option String) := do
  let kohakuHome ← match (← IO.getEnv "KOHAKU_HOME") with
    | some s => pure (System.FilePath.mk s)
    | none =>
        match (← IO.getEnv "HOME") with
        | some h => pure ((System.FilePath.mk h) / ".kohaku")
        | none   => pure (System.FilePath.mk ".kohaku")
  let indexFile := kohakuHome / "checkout"
  if !(← indexFile.pathExists) then return none
  let raw ← IO.FS.readFile indexFile
  let checkout := (System.FilePath.mk raw.toSubstring.trim.toString)
  let candidate := checkout / "bridge" / "colibri" / "bridge.mjs"
  if (← candidate.pathExists) then pure (some candidate.toString) else pure none

/-- Resolve the bridge executable in this order:
    1. `LEAN_KOHAKU_COLIBRI_BRIDGE` env var (explicit override).
    2. `bridge/colibri/bridge.mjs` walked upward from CWD (monorepo).
    3. `$KOHAKU_HOME/checkout` → `bridge/colibri/bridge.mjs` (kohakuspawn-installed).
    4. `leankohaku-colibri-bridge` on PATH (installed binary). -/
def resolveExecutable : IO String := do
  match (← IO.getEnv "LEAN_KOHAKU_COLIBRI_BRIDGE") with
  | some s => pure s
  | none =>
      let cwd ← IO.currentDir
      match ← findBridgeMjs cwd 8 with
      | some p => pure p
      | none =>
          match ← findBridgeViaRecordedCheckout with
          | some p => pure p
          | none => pure defaultExecutable

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
  deriving Repr

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
    pure (Response.crash s!"transport error: {e}")

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

/-- Tear down the connection. The sidecar exits on the resulting EOF. -/
def close (c : Client) : IO Unit := do
  try shutdown c.conn catch _ => pure ()
  try LeanKohaku.Transport.Uds.close c.conn catch _ => pure ()

end LeanKohaku.Colibri.Persistent
