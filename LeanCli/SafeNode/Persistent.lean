import LeanCli.Encoding.Json
import LeanCli.Transport.Uds
import LeanCli.Util.BridgeResolve

/-!
# Daemon-managed persistent safenode client

Spawns the safenode sidecar in `--listen <socket>` mode and holds a
UDS connection for the daemon's lifetime. The sidecar's cold-start
runs the full TDX-quote verification flow (fetch `/attestation`, shell
out to the Rust `tdx_quote_verifier`, replay RTMR3, derive the
attested TLS pin), so amortizing it across every safenode-routed read
in the session is a meaningful win.

The wire protocol on the UDS is newline-delimited JSON-RPC:

  → {"jsonrpc":"2.0","method":"safenode.status","params":{},"id":N}\n
  ← {"jsonrpc":"2.0","id":N,"result":...}\n

The HTTP proxy plane (`http://127.0.0.1:<port>`) is exposed by the
sidecar separately; the daemon reads its URL from
`safenode.proxyUrl` / `safenode.status` and feeds it to helios as
`executionRpc`. This module deliberately does not proxy HTTP traffic
through the UDS — helios talks directly to the sidecar's HTTP port,
which keeps the daemon out of the per-`eth_getProof` data path.

Trust posture: identical to the one-shot bridge. The sidecar's output
is consumed by helios's verification (Merkle proofs against the
consensus state root); a compromised sidecar can refuse to serve
proofs but cannot silently substitute them. Signing decisions still
terminate at `ConfirmGate`.

This module is the **only** place that spawns the safenode sidecar in
`--listen` mode.
-/

namespace LeanCli.SafeNode.Persistent

open LeanCli.Encoding.Json
open LeanCli.Transport.Uds

/-- A live connection to the persistent safenode sidecar plus the next
    request id. The line buffer holds bytes read past a newline so the
    next `recv` doesn't lose framing. Same shape as
    `Helios.Persistent.Client`. -/
structure Client where
  conn   : Conn
  socket : String
  pidFd  : Option UInt32
  nextId : IO.Ref Nat
  buf    : IO.Ref ByteArray
  /-- Cached local HTTP proxy URL the sidecar advertised at startup.
      The daemon hands this URL to helios as `executionRpc` so every
      `eth_getProof` lookup tunnels through the TDX-pinned channel. -/
  proxyUrl : IO.Ref (Option String)

/-- Default executable name for the safenode sidecar. -/
def defaultExecutable : String := "leancli-safenode-bridge"

/-- Resolve via the shared `BridgeResolve` chain. Mirrors the helios /
    colibri resolvers. -/
def resolveExecutable : IO String :=
  LeanCli.Util.BridgeResolve.resolveExecutable
    "LEANCLI_SAFENODE_BRIDGE"
    ("sidecars" / "kohaku" / "safenode" / "bridge.mjs")
    defaultExecutable

/-- Spawn the sidecar in --listen mode and connect to it. The sidecar
    runs the TDX verify flow before binding either socket; if that
    fails, the spawned process exits non-zero and `connect` will fail
    here. The caller is responsible for keeping the returned `Client`
    alive for the daemon's lifetime.

    `extraEnv` is overlaid on the spawned child's env. The daemon uses
    this to default `LEANCLI_SAFE_NODE_FALLBACK_RPC` to its own
    configured Sepolia endpoint without polluting its own env. -/
def start (socketPath : String) (extraEnv : Array (String × String) := #[]) : IO Client := do
  let exe ← resolveExecutable
  -- Sidecar writes no on-disk state; CWD is incidental. Keep it under
  -- cache/safenode/ for parity with helios/colibri.
  let cacheDir : System.FilePath := (← IO.currentDir) / "cache" / "safenode"
  IO.FS.createDirAll cacheDir
  let envArr : Array (String × Option String) := extraEnv.map (fun (k, v) => (k, some v))
  let _child ← IO.Process.spawn {
    cmd := exe,
    args := #["--listen", socketPath],
    cwd := some cacheDir.toString,
    env := envArr,
    stdin := .null,
    stdout := .null,
    stderr := .inherit
  }
  -- The sidecar runs the TDX verify flow before binding either
  -- socket, which can take a few seconds (Rust verifier + network
  -- round-trips). Give it more retry headroom than helios.
  let mut tries : Nat := 0
  let mut connected : Option Conn := none
  while connected.isNone && tries < 200 do
    try
      let c ← connect socketPath
      connected := some c
    catch _ =>
      IO.sleep 100
      tries := tries + 1
  match connected with
  | none =>
      throw (IO.userError s!"safenode persistent: could not connect to {socketPath} after {tries} retries (TDX verify probably failed; check sidecar stderr)")
  | some conn =>
      let nextId ← IO.mkRef 1
      let buf ← IO.mkRef (ByteArray.empty)
      let proxyUrl ← IO.mkRef (none : Option String)
      pure { conn, socket := socketPath, pidFd := none, nextId, buf, proxyUrl }

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
          throw (IO.userError "safenode persistent: connection closed")
        c.buf.set (buf ++ chunk)
        scan
  scan

private def writeAll (c : Client) (bytes : ByteArray) : IO Unit := do
  let mut remaining := bytes
  while remaining.size > 0 do
    let n ← write c.conn remaining
    if n == 0 then
      throw (IO.userError "safenode persistent: short write")
    remaining := remaining.extract n.toNat remaining.size

inductive Response where
  | ok    (result : Json)
  | err   (code : Int) (message : String) (data : Option Json)
  | crash (reason : String)
  /-- Transport-level failure on the UDS conn (broken pipe / closed /
      short write). Distinct from `crash` so the daemon can decide to
      respawn vs. propagate. Mirrors `Helios.Persistent.Response`. -/
  | transportCrash (reason : String)
  deriving Repr

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
  | .error e => Response.crash s!"safenode returned non-JSON ({e}): {raw}"
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
            | _ => "safenode error"
          let data := (ef.find? (fun (k, _) => k == "data")).map Prod.snd
          Response.err code msg data
      | _ =>
          match lookup "result" with
          | some j => Response.ok j
          | none => Response.crash s!"safenode response missing result: {raw}"
  | .ok _ => Response.crash s!"safenode response not a JSON object: {raw}"

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

def close (c : Client) : IO Unit := do
  try shutdown c.conn catch _ => pure ()
  try LeanCli.Transport.Uds.close c.conn catch _ => pure ()

/-- Query the sidecar for its local HTTP proxy URL and cache it on the
    client. Idempotent: subsequent calls return the cached value
    without round-tripping. The daemon feeds this URL to helios as
    `executionRpc`, so every helios-routed `eth_getProof` lookup tunnels
    through the TDX-pinned channel.

    Returns `none` if the sidecar reports no proxy URL (which would be
    a sidecar bug — the listen-mode handler always populates it). -/
def getProxyUrl (c : Client) : IO (Option String) := do
  match ← c.proxyUrl.get with
  | some url => pure (some url)
  | none =>
      let resp ← call c "safenode.proxyUrl" (.obj #[])
      match resp with
      | .ok (.obj fields) =>
          match (fields.find? (fun (k, _) => k == "proxyUrl")).map Prod.snd with
          | some (.str url) =>
              c.proxyUrl.set (some url)
              pure (some url)
          | _ => pure none
      | _ => pure none

/-- Force a refresh of the cached proxy URL. Useful after
    `safenode.verify` re-attests (the URL doesn't actually change in
    that case, but a stale-cache bug would be silent otherwise). -/
def refreshProxyUrl (c : Client) : IO (Option String) := do
  c.proxyUrl.set none
  getProxyUrl c

end LeanCli.SafeNode.Persistent
