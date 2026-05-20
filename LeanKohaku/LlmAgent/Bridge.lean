import LeanKohaku.Encoding.Json
import LeanKohaku.Util.Sandbox
import LeanKohaku.Util.BridgeResolve

/-!
# LLM-agent bridge

Untrusted Node sidecar (`bridge/llm/`) that turns natural-language intents
into transaction-draft candidates. The Lean daemon is the trusted policy
enforcer; this process is treated as malicious. Every draft it emits flows
through the existing decode → simulate → user-confirm gate before any
signing happens.

Same one-shot stdio pattern as `LeanKohaku.Privacy.Bridge` and
`LeanKohaku.Clearsign.Bridge`. This module is the **only** place that
spawns the llm sidecar.
-/

namespace LeanKohaku.LlmAgent.Bridge

open LeanKohaku.Encoding.Json

def defaultExecutable : String := "leankohaku-llm-bridge"

/-- Resolve via the shared `BridgeResolve` chain
    (env → cwd-walk → recorded-checkout → PATH fallback).
    See `LeanKohaku/Util/BridgeResolve.lean` for the resolution order. -/
def resolveExecutable : IO String :=
  LeanKohaku.Util.BridgeResolve.resolveExecutable
    "LEAN_KOHAKU_LLM_BRIDGE"
    ("bridge" / "llm" / "bridge.mjs")
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
  | .error e => Response.crash s!"llm returned non-JSON ({e}): {raw}" 0
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
            | _ => "llm bridge error"
          let data := (ef.find? (fun (k, _) => k == "data")).map Prod.snd
          Response.err code msg data
      | _ =>
          match lookup "result" with
          | some j => Response.ok j
          | none => Response.crash s!"llm response missing result: {raw}" 0
  | .ok _ => Response.crash s!"llm response not a JSON object: {raw}" 0

def call (req : Request) : IO Response := do
  let exe ← resolveExecutable
  let encoded := encodeRequest req
  try
    -- Sandbox the LLM sidecar. needsTcpLoopback=true keeps the host
    -- network namespace because this sidecar must reach the local
    -- llama-server at 127.0.0.1:8080. The loopback-only URL guard in
    -- bridge/llm/src/clients/ is the policy layer that prevents the
    -- sidecar from reaching anything *but* loopback.
    let (cmd, args) ← LeanKohaku.Util.Sandbox.wrap
      { cmd := exe, args := #["--rpc", encoded], needsTcpLoopback := true }
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
    else if !stdout.trim.isEmpty then
      pure (parseResponse stdout)
    else
      pure (Response.crash s!"llm exited with code {exitCode}" exitCode)
  catch e =>
    pure (Response.crash (toString e) 0)

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

end LeanKohaku.LlmAgent.Bridge
