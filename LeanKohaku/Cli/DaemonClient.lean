import LeanKohaku.Encoding.Json
import LeanKohaku.Transport.Uds

/-!
# Thin daemon client

Small JSON-RPC client for CLI commands. It transports JSON over the local Unix
socket and does not perform wallet operations locally.
-/

namespace LeanKohaku.Cli.DaemonClient

open LeanKohaku.Encoding.Json

structure RpcError where
  code    : Int
  message : String
  deriving Repr

def runtimeDir : IO String := do
  match ← IO.getEnv "XDG_RUNTIME_DIR" with
  | some dir => pure dir
  | none => pure "/tmp"

def defaultSocketPath : IO String := do
  pure s!"{← runtimeDir}/leankohaku/leankohaku.sock"

def socketPath : IO String := do
  match ← IO.getEnv "LEANKOHAKU_SOCKET" with
  | some path => pure path
  | none => defaultSocketPath

def daemonBin : IO String := do
  match ← IO.getEnv "LEANKOHAKU_DAEMON_BIN" with
  | some path => pure path
  | none =>
      let candidate := (← IO.appDir) / "leankohaku-daemon"
      if ← candidate.pathExists then
        pure candidate.toString
      else
        pure "leankohaku-daemon"

def autoSpawnDisabled : IO Bool := do
  match ← IO.getEnv "LEANKOHAKU_NO_AUTOSPAWN" with
  | none => pure false
  | some "" => pure false
  | some "0" => pure false
  | some "false" => pure false
  | some "FALSE" => pure false
  | some _ => pure true

def noAutoSpawnMethod (method : String) : Bool :=
  method == "daemon.shutdown"

def spawnDaemon (path : String) : IO Unit := do
  let bin ← daemonBin
  discard <| IO.Process.spawn
    { cmd := bin,
      env := #[("LEANKOHAKU_SOCKET", some path)],
      stdin := .null,
      stdout := .null,
      stderr := .null,
      setsid := true }

partial def waitForSocketConnect (path : String) (remaining : Nat) : IO Bool := do
  if remaining == 0 then
    pure false
  else
    try
      let conn ← LeanKohaku.Transport.Uds.connect path
      LeanKohaku.Transport.Uds.close conn
      pure true
    catch _ =>
      IO.sleep 100
      waitForSocketConnect path (remaining - 1)

def ensureDaemon (path method : String) : IO Bool := do
  if noAutoSpawnMethod method || (← autoSpawnDisabled) then
    pure false
  else
    spawnDaemon path
    waitForSocketConnect path 20

def requestJson (method : String) (params : Json) : Json :=
  .obj #[
    ("jsonrpc", .str "2.0"),
    ("method", .str method),
    ("params", params),
    ("id", .num 1)
  ]

def parseRpcError (json : Json) : RpcError :=
  let code :=
    match getField "code" json with
    | some (.num n) => n
    | _ => -32000
  let message :=
    match getField "message" json >>= asString with
    | some msg => msg
    | none => "daemon error"
  let message :=
    match getField "data" json with
    | some data => message ++ ": " ++ compact data
    | none => message
  { code := code, message := message }

/-- Render a JSON-RPC notification frame from the daemon. Known events
    get a friendly one-liner; unknown events are surfaced verbatim so
    new event types light up automatically. -/
def renderNotification (params : Json) : IO Unit := do
  let event := getField "event" params >>= asString
  let data := (getField "data" params).getD (.obj #[])
  let op := (getField "op" data >>= asString).getD ""
  let opLabel := if op.isEmpty then "" else s!" ({op})"
  match event with
  | some "pin-required" =>
      IO.println s!"🔒 Verifying TPM PIN{opLabel}…"
  | some "pin-success" =>
      IO.println s!"✓ PIN accepted{opLabel}"
  | some "pin-auth-failed" =>
      let reason := (getField "stderr" data >>= asString).getD ""
      let trimmed := reason.trim
      if trimmed.isEmpty then
        IO.println s!"✗ PIN rejected by TPM{opLabel}"
      else
        IO.println s!"✗ PIN rejected by TPM{opLabel}: {trimmed}"
  | some "pin-locked-out" =>
      let reason := (getField "stderr" data >>= asString).getD ""
      let trimmed := reason.trim
      if trimmed.isEmpty then
        IO.println s!"⛔ TPM dictionary-attack lockout — wait for the lockout to elapse{opLabel}"
      else
        IO.println s!"⛔ TPM dictionary-attack lockout{opLabel}: {trimmed}"
  | some "tx-broadcasted" =>
      let txHash := (getField "txHash" data >>= asString).getD "?"
      IO.println s!"📡 Broadcast: {txHash}"
  | some "tx-pending" =>
      let elapsed := (getField "elapsedSec" data >>= asNat).getD 0
      IO.println s!"⏳ Waiting for confirmation… ({elapsed}s)"
  | some "tx-mined" =>
      let parseHex (s : String) : Option Nat :=
        let chars := s.toList
        let body :=
          match chars with
          | '0' :: 'x' :: rest => rest
          | '0' :: 'X' :: rest => rest
          | _ => chars
        body.foldl
          (init := some 0)
          (fun acc c =>
            let d? : Option Nat :=
              if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
              else if 'a' ≤ c && c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
              else if 'A' ≤ c && c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
              else none
            match acc, d? with
            | some n, some d => some (n * 16 + d)
            | _, _ => none)
      let blockHex := (getField "blockNumber" data >>= asString).getD ""
      let gasHex := (getField "gasUsed" data >>= asString).getD ""
      let priceHex := (getField "effectiveGasPrice" data >>= asString).getD ""
      let status := (getField "status" data >>= asString).getD "?"
      let block := (parseHex blockHex).getD 0
      let gasUsed := (parseHex gasHex).getD 0
      let priceWei := (parseHex priceHex).getD 0
      let priceGweiWhole := priceWei / 1000000000
      let priceGweiFrac := priceWei % 1000000000
      let priceStr :=
        if priceGweiFrac = 0 then s!"{priceGweiWhole} gwei"
        else
          let s := toString priceGweiFrac
          let pad := String.mk (List.replicate (9 - s.length) '0')
          let trimmed := (pad ++ s).dropRightWhile (· = '0')
          s!"{priceGweiWhole}.{trimmed} gwei"
      IO.println s!"✓ Mined in block {block} — gasUsed={gasUsed}, effectivePrice={priceStr}, status={status}"
  | some name =>
      IO.println s!"[event] {name} {compact data}"
  | none =>
      IO.println s!"[event] {compact params}"

/-- Split a buffer into complete (newline-terminated) frames plus a
    trailing partial line. Returns `(complete-lines, leftover)`. -/
def splitFrames (buf : String) : List String × String :=
  let parts := buf.splitOn "\n"
  match parts.reverse with
  | [] => ([], "")
  | last :: revInit => (revInit.reverse, last)

/-- Try to extract a final response (or render a notification) from
    one parsed frame. Returns `some` for the response frame, `none`
    after rendering a notification. -/
def consumeFrame (trimmed : String) : IO (Option (Except RpcError Json)) := do
  if trimmed.isEmpty then
    pure none
  else
    match parse trimmed with
    | .error err =>
        pure (some (.error { code := -32700, message := err }))
    | .ok response =>
        let hasResult := (getField "result" response).isSome
        let hasError := (getField "error" response).isSome
        if !hasResult && !hasError then
          match getField "params" response with
          | some p => renderNotification p
          | none => renderNotification response
          pure none
        else
          match getField "result" response, getField "error" response with
          | some result, _ => pure (some (.ok result))
          | _, some err => pure (some (.error (parseRpcError err)))
          | _, _ => pure (some (.error { code := -32603, message := "malformed daemon response" }))

partial def processFrames :
    List String → IO (Option (Except RpcError Json))
  | [] => pure none
  | frame :: rest => do
      match ← consumeFrame frame.trim with
      | some result => pure (some result)
      | none => processFrames rest

/-- Read & dispatch frames until we get the response frame for our
    request. Notification frames are rendered inline; the response
    frame is returned. Buffers across `read` chunks so partial frames
    don't break parsing. -/
partial def readUntilResponse (conn : LeanKohaku.Transport.Uds.Conn)
    (buffer : String) : IO (Except RpcError Json) := do
  let (complete, leftover) := splitFrames buffer
  match ← processFrames complete with
  | some result => pure result
  | none =>
      let bytes ← LeanKohaku.Transport.Uds.read conn
      if bytes.isEmpty then
        pure (.error { code := -32603, message := "daemon closed connection before responding" })
      else
        let some chunk := String.fromUTF8? bytes
          | pure (.error { code := -32700, message := "daemon returned non-UTF8 response" })
        readUntilResponse conn (leftover ++ chunk)

def callOnce (path method : String) (params : Json := .arr #[]) : IO (Except RpcError Json) := do
  let conn ← LeanKohaku.Transport.Uds.connect path
  try
    discard <| LeanKohaku.Transport.Uds.write conn (compact (requestJson method params) ++ "\n").toByteArray
    readUntilResponse conn ""
  finally
    LeanKohaku.Transport.Uds.close conn

def call (method : String) (params : Json := .arr #[]) : IO (Except RpcError Json) := do
  let path ← socketPath
  try
    callOnce path method params
  catch first =>
    if ← ensureDaemon path method then
      try
        callOnce path method params
      catch second =>
        pure (.error { code := -32000, message := second.toString })
    else
      pure (.error { code := -32000, message := first.toString })

def printCall (method : String) (params : Json := .arr #[]) : IO UInt32 := do
  match ← call method params with
  | .ok result =>
      IO.println (pretty result)
      pure 0
  | .error err =>
      IO.eprintln s!"daemon error {err.code}: {err.message}"
      pure 2

def printTextResult (method : String) (params : Json := .arr #[]) : IO UInt32 := do
  match ← call method params with
  | .ok result =>
      match getField "text" result >>= asString with
      | some text => IO.print text
      | none => IO.println (pretty result)
      match getField "exitCode" result >>= asNat with
      | some code => pure (UInt32.ofNat code)
      | none => pure 0
  | .error err =>
      IO.eprintln s!"daemon error {err.code}: {err.message}"
      pure 2

/- Keep no code below this point; the client must stay transport-only. -/

end LeanKohaku.Cli.DaemonClient
