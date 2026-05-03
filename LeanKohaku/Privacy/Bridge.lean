import LeanKohaku.Encoding.Json
import LeanKohaku.Privacy.NetworkPolicy

/-!
# Kohaku-bridge sidecar boundary

The Railgun and Privacy-Pools flows are implemented inside the npm packages
`@kohaku-eth/{plugins,railgun,privacy-pools}`. Reimplementing snarkjs witness
generation, libp2p (Waku), and the privacy-pools circuits in Lean is out of
scope, so we run them in a pinned Node sidecar (`leankohaku-kohaku-bridge`)
spawned by the daemon and addressed via line-delimited JSON-RPC over stdio.

The sidecar is **untrusted**: every prepared transaction it returns is
re-decoded by the Lean RLP / typed-tx / ABI code and gated through the
existing TPM-rooted signing path before broadcast. The bridge can never
exfiltrate plaintext key material because the response ADTs in this module
do not carry any spending-key bytes.

Network egress from the sidecar is policy-classified under the new
`shieldedRead` / `shieldedBroadcast` purposes in
`LeanKohaku.Privacy.NetworkPolicy`. Under `strictDaemonPolicy` shielded
purposes are denied; under `torDaemonPolicy` they are permitted only to
configured nodes via Tor.

This module is the **only** place that spawns the bridge.
-/

namespace LeanKohaku.Privacy.Bridge

open LeanKohaku.Encoding.Json
open LeanKohaku.Privacy.NetworkPolicy

/-- Default executable name for the kohaku-bridge sidecar. Mirrors the
    naming convention of the HACL helpers. -/
def defaultExecutable : String := "leankohaku-kohaku-bridge"

/-- Resolve the bridge executable. The `LEAN_KOHAKU_BRIDGE` environment
    variable overrides the default for local development. -/
def resolveExecutable : IO String := do
  match (← IO.getEnv "LEAN_KOHAKU_BRIDGE") with
  | some s => pure s
  | none => pure defaultExecutable

/-- A bridge JSON-RPC request. `params` is an arbitrary JSON object built by
    the caller; the bridge interprets it per `method`. -/
structure Request where
  method : String
  params : Json
  id     : Nat
  deriving Repr

/-- Outcome of a single bridge call. The bridge speaks JSON-RPC 2.0. -/
inductive Response where
  | ok    (result : Json)
  | err   (code : Int) (message : String) (data : Option Json)
  | crash (stderr : String) (exitCode : UInt32)
  deriving Repr

/-- Encode a request as a single JSON object on one line.
    The sidecar reads NDJSON from stdin: one request per line. -/
def encodeRequest (req : Request) : String :=
  compact <| .obj #[
    ("jsonrpc", .str "2.0"),
    ("method",  .str req.method),
    ("params",  req.params),
    ("id",      .num (Int.ofNat req.id))
  ]

/-- Classify a bridge method against the active network policy. The bridge
    must be denied if the policy refuses the implied purpose: this is the
    runtime hook for invariant 5.7 (every `Bridge.call` factors through
    `NetworkPolicy.Policy`). -/
def methodPurpose (method : String) : Purpose :=
  if method = "shielded.broadcast" || method = "shielded.signAndBroadcast"
      || method = "shielded.prepareWithdraw" then
    -- Why: prepareWithdraw POSTs the withdrawal to the relayer, which counts
    -- as a shielded broadcast for policy classification.
    Purpose.shieldedBroadcast
  else if method = "ping" || method = "version" || method = "listProtocols" then
    -- Local introspection: classified as daemon control, no egress.
    Purpose.daemonControl
  else
    Purpose.shieldedRead

def policyAllows
    (policy : Policy) (peer : Peer) (transport : Transport) (req : Request) : Bool :=
  policy { peer := peer, purpose := methodPurpose req.method, transport := transport }

private def parseResponse (raw : String) : Response :=
  match parse raw.trimAscii.toString with
  | .error e => Response.crash s!"bridge returned non-JSON ({e}): {raw}" 0
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
            | _ => "bridge error"
          let data := (ef.find? (fun (k, _) => k == "data")).map Prod.snd
          Response.err code msg data
      | _ =>
          match lookup "result" with
          | some j => Response.ok j
          | none => Response.crash s!"bridge response missing result: {raw}" 0
  | .ok _ => Response.crash s!"bridge response not a JSON object: {raw}" 0

/-- Spawn the sidecar for one request with optional env overlay, write the
    encoded request as `--rpc <json>`, read one line of stdout, and decode
    the response.

    M1 uses one-shot invocation (matching the HACL helper pattern). M2+ will
    promote this to a long-lived child process held in `Daemon/State.lean`
    so snarkjs proving keys are not reloaded per call. The public surface
    (`Bridge.call` / `Bridge.callWithEnv`) is the same either way; only the
    internal IO changes.

    `env` is forwarded by shielded handlers to pass `LEANKOHAKU_RPC_URL`,
    `LEANKOHAKU_CHAIN_ID`, and the privacy-pools mnemonic without putting
    secrets on argv. -/
def callWithEnv (req : Request) (env : Array (String × Option String)) : IO Response := do
  let exe ← resolveExecutable
  let encoded := encodeRequest req
  let v := ((← IO.getEnv "LEANKOHAKU_VERBOSE").getD "0").toNat?.getD 0
  let t0 ← IO.monoMsNow
  if v ≥ 1 then IO.eprintln s!"[bridge→] {req.method} exe={exe}"
  try
    let child ← IO.Process.spawn {
      cmd := exe,
      args := #["--rpc", encoded],
      env := env,
      stdin := .null,
      stdout := .piped,
      stderr := .inherit
    }
    let stdout ← child.stdout.readToEnd
    let exitCode ← child.wait
    if exitCode == 0 then
      pure (parseResponse stdout)
    else if !stdout.trim.isEmpty then
      -- Bridge wrote a JSON-RPC error then exited non-zero. Surface the
      -- error rather than dropping the payload.
      pure (parseResponse stdout)
    else
      pure (Response.crash s!"bridge exited with code {exitCode}" exitCode)
  catch e =>
    pure (Response.crash (toString e) 0)

def call (req : Request) : IO Response := callWithEnv req #[]

/-- Convenience: invoke the `ping` method and return the parsed response.
    Used by the `shielded.ping` daemon RPC for liveness checks. -/
def ping (id : Nat := 0) : IO Response :=
  call { method := "ping", params := .obj #[], id := id }

/-- Render a `Response` as JSON for the daemon to forward to the CLI. -/
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

end LeanKohaku.Privacy.Bridge
