import LeanCli.Encoding.Json
import LeanCli.Util.Sandbox
import LeanCli.Util.BridgeResolve

/-!
# Clearsign-bridge sidecar boundary

The ERC-7730 descriptor walker (calldata + EIP-712 → human intent) is
implemented in `sidecars/clearsign/` because viem already speaks the JSON-RPC
shapes we need (function-data decode, ABI parsing) and rewriting it in Lean
adds friction without security upside.

The sidecar is **untrusted** for signing decisions: its output is rendered
to the user as confirmation copy only. The Lean side never decides whether
to broadcast based on `intent` strings; it always re-decodes the signed tx
through the existing RLP / typed-tx / ABI path.

The sidecar performs no network IO, no key access, and no external API
calls — it loads vendored ERC-7730 JSON files at boot and walks them.

This module is the **only** place that spawns the clearsign sidecar.
-/

namespace LeanCli.Clearsign.Bridge

open LeanCli.Encoding.Json

/-- Default executable name for the clearsign sidecar (when on PATH). -/
def defaultExecutable : String := "leancli-clearsign-bridge"

/-- Resolve via the shared `BridgeResolve` chain
    (env → cwd-walk → recorded-checkout → PATH fallback).
    See `LeanCli/Util/BridgeResolve.lean` for the resolution order. -/
def resolveExecutable : IO String :=
  LeanCli.Util.BridgeResolve.resolveExecutable
    "LEANCLI_CLEARSIGN_BRIDGE"
    ("sidecars" / "clearsign" / "bridge.mjs")
    defaultExecutable

structure Request where
  method : String
  params : Json
  id     : Nat
  deriving Repr

inductive Response where
  | ok    (result : Json)
  | err   (code : Int) (message : String) (data : Option Json)
  | crash (stderr : String) (exitCode : UInt32)
  deriving Repr

def encodeRequest (req : Request) : String :=
  compact <| .obj #[
    ("jsonrpc", .str "2.0"),
    ("method",  .str req.method),
    ("params",  req.params),
    ("id",      .num (Int.ofNat req.id))
  ]

private def parseResponse (raw : String) : Response :=
  match parse raw.trimAscii.toString with
  | .error e => Response.crash s!"clearsign returned non-JSON ({e}): {raw}" 0
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
            | _ => "clearsign error"
          let data := (ef.find? (fun (k, _) => k == "data")).map Prod.snd
          Response.err code msg data
      | _ =>
          match lookup "result" with
          | some j => Response.ok j
          | none => Response.crash s!"clearsign response missing result: {raw}" 0
  | .ok _ => Response.crash s!"clearsign response not a JSON object: {raw}" 0

/-- Spawn the sidecar for one request, write the encoded request as
    `--rpc <json>`, read stdout, decode the response. Same one-shot
    pattern as `LeanCli.Privacy.Bridge.callWithEnv`. -/
def call (req : Request) : IO Response := do
  let exe ← resolveExecutable
  let encoded := encodeRequest req
  try
    -- Sandbox the clearsign sidecar. needsTcpLoopback=false — this
    -- sidecar walks vendored ERC-7730 JSON files at boot and has no
    -- network needs; running it in a fresh netns is purely upside.
    let (cmd, args) ← LeanCli.Util.Sandbox.wrap
      { cmd := exe, args := #["--rpc", encoded] }
    let child ← IO.Process.spawn {
      cmd := cmd,
      args := args,
      stdin := .null,
      stdout := .piped,
      stderr := .inherit
    }
    let stdout ← child.stdout.readToEnd
    let exitCode ← child.wait
    if exitCode == 0 then
      pure (parseResponse stdout)
    else if !stdout.trimAscii.toString.isEmpty then
      pure (parseResponse stdout)
    else
      pure (Response.crash s!"clearsign exited with code {exitCode}" exitCode)
  catch e =>
    pure (Response.crash (toString e) 0)

/-- Render a `Response` as JSON for forwarding to the CLI. Same shape as
    Privacy.Bridge.responseToJson. -/
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
  | .crash stderr exitCode =>
      .obj #[
        ("ok", .bool false),
        ("crash", .obj #[
          ("stderr", .str stderr),
          ("exitCode", .num (Int.ofNat exitCode.toNat))
        ])
      ]

end LeanCli.Clearsign.Bridge
