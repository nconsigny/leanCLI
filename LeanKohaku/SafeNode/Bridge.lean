import LeanKohaku.Encoding.Json

/-!
# safenode-bridge sidecar boundary

The safe-node sidecar (`bridge/safenode/bridge.mjs`) is a TDX-attested
oblivious-RPC proxy. At startup it runs the vendored
`verify_client_tdx.mjs` flow to fetch a TDX quote over
`domain + sha256(cert PEM) + challenge`, verify it locally via the
companion Rust binary `tdx_quote_verifier`, and derive the attested
TLS pin. Every outbound HTTPS request the sidecar makes is pinned to
that public key.

This module mirrors `LeanKohaku.Helios.Bridge` 1:1 (same `Request` /
`Response` / `call` / `responseToJson` shape) so the daemon dispatcher
can talk to the sidecar the same way it talks to helios/colibri.

The sidecar is **untrusted** for signing decisions: it's a proxy, not
an oracle. The integrity story is two-layered:

  1. The TDX attestation gives us strong evidence that the ORAM server
     is running the expected code and that we are talking to it (not a
     MITM with a forged-but-publicly-trusted cert).
  2. Every `eth_getProof` response the sidecar relays is consumed by
     helios's REVM, which Merkle-verifies it against the sync-committee-
     attested state root. If the ORAM server lies about a slot value,
     verification fails and the read errors out — it cannot silently
     propagate.

The daemon **never** signs based on safenode output. Privacy from ORAM
plus integrity from helios is a chain-read story; the signing trust
anchor remains `ConfirmGate` at the end of `decode → simulate → user-confirm`.

This module is the **only** place that spawns the safenode sidecar in
one-shot `--rpc` mode. Long-running operation goes through
`LeanKohaku.SafeNode.Persistent`.
-/

namespace LeanKohaku.SafeNode.Bridge

open LeanKohaku.Encoding.Json

/-- Default executable name for the safenode sidecar (on PATH). -/
def defaultExecutable : String := "leankohaku-safenode-bridge"

/-- Resolve the bridge executable. `LEAN_KOHAKU_SAFENODE_BRIDGE`
    overrides for local development. -/
def resolveExecutable : IO String := do
  match (← IO.getEnv "LEAN_KOHAKU_SAFENODE_BRIDGE") with
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
  | .error e => Response.crash s!"safenode returned non-JSON ({e}): {raw}" 0
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
          | none => Response.crash s!"safenode response missing result: {raw}" 0
  | .ok _ => Response.crash s!"safenode response not a JSON object: {raw}" 0

/-- Spawn the sidecar for one request, write the encoded request as
    `--rpc <json>`, read stdout, decode the response. Same one-shot
    pattern as `LeanKohaku.Helios.Bridge.call`. -/
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
      pure (Response.crash s!"safenode exited with code {exitCode}" exitCode)
  catch e =>
    pure (Response.crash (toString e) 0)

/-- Render a `Response` as JSON for forwarding to the CLI. Mirrors
    `Helios.Bridge.responseToJson`. -/
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

end LeanKohaku.SafeNode.Bridge
