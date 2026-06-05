import LeanCli.Encoding.Json
import LeanCli.Network.Policy
import LeanCli.Util.Sandbox
import LeanCli.Util.BridgeResolve

/-!
# leanCLI-bridge sidecar boundary

The Railgun and Privacy-Pools flows are implemented inside the npm packages
`@kohaku-eth/{plugins,railgun,privacy-pools}`. Reimplementing snarkjs witness
generation, libp2p (Waku), and the privacy-pools circuits in Lean is out of
scope, so we run them in a pinned Node sidecar (`leancli-bridge`)
spawned by the daemon and addressed via line-delimited JSON-RPC over stdio.

The sidecar is **untrusted**: every prepared transaction it returns is
re-decoded by the Lean RLP / typed-tx / ABI code and gated through the
existing TPM-rooted signing path before broadcast. The bridge can never
exfiltrate plaintext key material because the response ADTs in this module
do not carry any spending-key bytes.

Network egress from the sidecar is policy-classified under the new
`shieldedRead` / `shieldedBroadcast` purposes in
`LeanCli.Network.Policy`. Under `strictDaemonPolicy` shielded
purposes are denied; under `torDaemonPolicy` they are permitted only to
configured nodes via Tor.

This module is the **only** place that spawns the bridge.
-/

namespace LeanCli.Privacy.Bridge

open LeanCli.Encoding.Json
open LeanCli.Network.Policy

/-- Default executable name for the leancli-bridge sidecar. Used as the
    PATH-resolved fallback when nothing more specific is configured. -/
def defaultExecutable : String := "leancli-bridge"

/-- Resolve via the shared `BridgeResolve` chain
    (env → cwd-walk → recorded-checkout → PATH fallback).
    See `LeanCli/Util/BridgeResolve.lean` for the resolution order.
    Replaced the old "cwd-only" check, which failed for systemd-managed
    daemons whose cwd was outside the checkout. -/
def resolveExecutable : IO String :=
  LeanCli.Util.BridgeResolve.resolveExecutable
    "LEANCLI_BRIDGE"
    ("sidecars" / "kohaku" / "bridge.mjs")
    defaultExecutable

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
      || method = "shielded.prepareWithdraw"
      -- Railgun unshield/transfer build a private op AND relay it via the
      -- bundled Waku broadcaster inside the bridge handler, mirroring PP's
      -- shielded.prepareWithdraw. Classify as broadcast so the policy gate
      -- denies them under strict-mainnet.
      || method = "shielded.railgun.unshield"
      || method = "shielded.railgun.transfer" then
    -- Why: prepareWithdraw POSTs the withdrawal to the relayer, which counts
    -- as a shielded broadcast for policy classification.
    Purpose.shieldedBroadcast
  else if method = "ping" || method = "version" || method = "listProtocols" then
    -- Local introspection: classified as daemon control, no egress.
    Purpose.daemonControl
  else
    -- Read-only shielded queries (shielded.balance, shielded.railgun.balance,
    -- shielded.prepareDeposit, shielded.railgun.prepareShield*) fall here.
    -- The shield/prepareDeposit return TxData the daemon broadcasts via the
    -- existing eth-broadcast path, not via the sidecar.
    Purpose.shieldedRead

/-- Run the network policy over a shielded bridge request. `chainId` is
plumbed through so the chain-aware default policy
(`mainnetSafeDaemonPolicy`) can permit configured-node shielded
operations on testnets and keep them strict on mainnet. Omitting the
chainId leaves the request opaque to the policy's testnet branch and
the strict path denies it — that was the source of the
"shielded surface denied by policy" failure on sepolia. -/
def policyAllows
    (policy : Policy) (peer : Peer) (transport : Transport) (req : Request)
    (chainId : Option Nat := none) : Bool :=
  policy { peer := peer, purpose := methodPurpose req.method, transport := transport, chainId := chainId }

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

    `env` is forwarded by shielded handlers to pass `LEANCLI_RPC_URL`,
    `LEANCLI_CHAIN_ID`, and the privacy-pools mnemonic without putting
    secrets on argv. -/
def callWithEnv (req : Request) (env : Array (String × Option String)) : IO Response := do
  let exe ← resolveExecutable
  let encoded := encodeRequest req
  let v := ((← IO.getEnv "LEANCLI_VERBOSE").getD "0").toNat?.getD 0
  let t0 ← IO.monoMsNow
  -- Forward the daemon's `LEANCLI_PRIVACY` allow-list explicitly into the
  -- sidecar env (TASK 3). The host (`bridge.mjs`) reads it to gate
  -- `shielded.*` per plugin: a disabled plugin's method returns
  -- `{ ok:false, error:"plugin not enabled: <name>" }` without lazy-loading
  -- its code. Passing it through the explicit env array (rather than relying
  -- on inheritance) keeps the value present across the sandbox wrap. Caller-
  -- supplied entries win, so a test can still override.
  let env ←
    if env.any (fun (k, _) => k == "LEANCLI_PRIVACY") then pure env
    else
      match ← IO.getEnv "LEANCLI_PRIVACY" with
      | some p => pure (env.push ("LEANCLI_PRIVACY", some p))
      | none   => pure env
  if v ≥ 1 then IO.eprintln s!"[bridge→] {req.method} exe={exe}"
  try
    -- Sandbox the privacy sidecar. Conservatively keep host network
    -- namespace (needsTcpLoopback := true): the snarkjs / libp2p / Waku
    -- sidecar may reach beyond loopback today; tightening to UDS-only
    -- belongs in a follow-up after auditing the sidecar's actual
    -- traffic. PID/UTS/IPC isolation still applies regardless.
    let (cmd, args) ← LeanCli.Util.Sandbox.wrap
      { cmd := exe, args := #["--rpc", encoded], needsTcpLoopback := true }
    -- Pipe stderr too so a crash inside the sidecar (snarkjs proving
    -- key not found, libp2p stack trace, env-validation failure, …)
    -- gets surfaced to the TUI's error block instead of vanishing into
    -- the daemon's terminal. Was `.inherit` before — that hid the
    -- actual root cause behind a generic "exited with code N".
    let child ← IO.Process.spawn {
      cmd := cmd,
      args := args,
      env := env,
      stdin := .null,
      stdout := .piped,
      stderr := .piped
    }
    let stdout ← child.stdout.readToEnd
    let stderr ← child.stderr.readToEnd
    let exitCode ← child.wait
    -- Tee the captured stderr to the daemon's stderr too, so the daemon
    -- log retains everything when sandboxing or systemd capture is in
    -- effect.
    let stderrClean := stderr.trimAscii.toString
    if !stderrClean.isEmpty then IO.eprintln stderr
    if exitCode == 0 then
      pure (parseResponse stdout)
    else if !stdout.trimAscii.toString.isEmpty then
      -- Bridge wrote a JSON-RPC error then exited non-zero. Surface the
      -- error rather than dropping the payload.
      pure (parseResponse stdout)
    else
      -- Include the captured stderr in the crash message so the user
      -- sees the actual root cause (e.g. "Error: missing snarkjs witness
      -- file"), not just "bridge exited with code 255".
      let limited :=
        if stderrClean.length > 1500
          then (stderrClean.take 1500).toString ++ "\n…[truncated]"
          else stderrClean
      let msg :=
        if limited.isEmpty then s!"bridge exited with code {exitCode}"
        else s!"bridge exited with code {exitCode}; stderr:\n{limited}"
      pure (Response.crash msg exitCode)
  catch e =>
    pure (Response.crash (toString e) 0)

def call (req : Request) : IO Response := callWithEnv req #[]

/-- Fixed denial response for a policy-rejected bridge request. The
    `-32030` code matches the daemon's pre-existing "shielded surface
    denied by policy" error so callers see the same envelope whether the
    gate fires at the call site or inside the dispatcher. -/
def policyDenial (req : Request) : Response :=
  Response.err (-32030) "shielded surface denied by policy"
    (some (.str ("policy denies " ++ req.method)))

/-- Pure gate decision for invariant 5.7. The classification models the
    sidecar's *outbound* network reach, not the fact that it is a local
    child process: a shielded operation talks to Railgun / Privacy-Pools
    relayers and configured nodes, so the egress peer is
    `.configuredNode` and the transport `.direct`. The policy then rules
    on the request's `methodPurpose` and `chainId`.

    Divergence note (vs. the Stream B task's suggested
    `peer := .localNode, transport := .loopback`): in
    `LeanCli.Network.Policy`, shielded purposes are *only ever* permitted
    for `peer := .configuredNode` (mainnet-strict denies them; testnet,
    tor, dev, and permissive allow `.configuredNode` shielded). Using
    `.localNode` would deny every shielded operation under every policy —
    a trust-posture-changing regression. The existing call-site gate in
    `shieldedBridgeCall` already used `.configuredNode .direct`; this
    keeps the exact same allow/deny outcome while moving the gate inside
    the dispatcher so no call site can bypass it.

    `.error (policyDenial req)` ⇒ deny (do NOT spawn).
    `.ok ()`                   ⇒ allow (proceed to spawn). -/
def gateDecision (policy : Policy) (req : Request) (chainId : Option Nat) :
    Except Response Unit :=
  if policyAllows policy .configuredNode .direct req chainId then
    .ok ()
  else
    .error (policyDenial req)

/-- Policy-gated bridge call (runtime hook for invariant 5.7). Every
    `shielded.*` dispatch must route through here rather than calling
    `callWithEnv` directly: the gate is evaluated and a denied request
    returns `policyDenial` BEFORE any process is spawned, so a
    policy-denied shielded operation can never reach the sidecar.

    `callWithEnv` remains the un-gated transport primitive, used here
    after the gate clears and by out-of-band dev tools (e.g. the
    `leancli-railgun-snapshot` generator) that run outside the daemon's
    policy context entirely. -/
def callGated (policy : Policy) (req : Request)
    (env : Array (String × Option String)) (chainId : Option Nat := none) :
    IO Response := do
  match gateDecision policy req chainId with
  | .error denial => pure denial
  | .ok () => callWithEnv req env

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

end LeanCli.Privacy.Bridge
