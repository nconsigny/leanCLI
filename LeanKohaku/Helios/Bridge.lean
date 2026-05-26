import LeanKohaku.Encoding.Json

/-!
# Helios-bridge sidecar boundary

Local EVM simulation backed by `@a16z/helios`, a trustless Rust light
client that validates execution payloads against sync-committee proofs
and executes `eth_call` / `eth_estimateGas` inside an embedded REVM.

Mirrors `LeanKohaku.Colibri.Bridge` 1:1 (same `Request` / `Response` /
`call` / `responseToJson` shape) so the daemon dispatcher can swap
backends without restructuring its handlers. The differences live
sidecar-side: Helios requires a fallback `executionRpc` URL (the a16z
client cannot serve `eth_getLogs` from sync-committee state and falls
back to the configured RPC), so every Helios-targeted method carries
both `chainId` and `executionRpc` in its params.

The sidecar is **untrusted** for signing decisions: its output is
rendered to the user as confirmation copy only (TransfersBlock +
ConfirmGate). The Lean side never decides whether to broadcast based on
its `gasUsed` / `returnValue` / `revertReason`; it always re-decodes
the signed tx through the existing RLP / typed-tx / ABI path.

The sidecar performs network IO (beacon API + execution RPC) but no key
access. Network access is allowed because that is how trustless
verification works; trust is anchored at the consensus sync committee,
not at the RPC provider.

This module is the **only** place that spawns the helios sidecar.
-/

namespace LeanKohaku.Helios.Bridge

open LeanKohaku.Encoding.Json

/-- Default executable name for the helios sidecar. -/
def defaultExecutable : String := "leankohaku-helios-bridge"

/-- Resolve the bridge executable. The `LEAN_KOHAKU_HELIOS_BRIDGE`
    environment variable overrides for local development. -/
def resolveExecutable : IO String := do
  match (← IO.getEnv "LEAN_KOHAKU_HELIOS_BRIDGE") with
  | some s => pure s
  | none => pure defaultExecutable

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
  | .error e => Response.crash s!"helios returned non-JSON ({e}): {raw}" 0
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
          | none => Response.crash s!"helios response missing result: {raw}" 0
  | .ok _ => Response.crash s!"helios response not a JSON object: {raw}" 0

/-- Spawn the sidecar for one request, write the encoded request as
    `--rpc <json>`, read stdout, decode the response. Same one-shot
    pattern as `LeanKohaku.Colibri.Bridge.call`. Helios's first
    cold-start can take several seconds (consensus sync), so callers
    should size their UI spinners accordingly and prefer the persistent
    client for read-heavy paths. -/
def call (req : Request) : IO Response := do
  let exe ← resolveExecutable
  let encoded := encodeRequest req
  try
    let child ← IO.Process.spawn {
      cmd := exe,
      args := #["--rpc", encoded],
      stdin := .null,
      stdout := .piped,
      stderr := .inherit
    }
    let stdout ← child.stdout.readToEnd
    let exitCode ← child.wait
    if exitCode == 0 then
      pure (parseResponse stdout)
    else if !stdout.trimAscii.isEmpty then
      pure (parseResponse stdout)
    else
      pure (Response.crash s!"helios exited with code {exitCode}" exitCode)
  catch e =>
    pure (Response.crash (toString e) 0)

/-- Render a `Response` as JSON for forwarding to the CLI. Same shape as
    `Colibri.Bridge.responseToJson`. -/
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

end LeanKohaku.Helios.Bridge
