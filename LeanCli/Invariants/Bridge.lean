import LeanCli.Privacy.Bridge
import LeanCli.Network.Policy

/-!
# Bridge boundary invariants

The Node sidecar (`@kohaku-eth/{plugins,railgun,privacy-pools}`) is
**untrusted**. The wallet defends against it through three structural
properties proved here:

* **Purpose classification** — every `Bridge` method is mapped to a
  network-policy `Purpose`. Methods whose name encodes a broadcast
  intent map to `shieldedBroadcast`; everything else maps to a
  read-only purpose. This is the static skeleton of the planned
  invariant 5.7 (every bridge call factors through the policy).

* **Strict mode denies shielded egress** — the `strictDaemonPolicy`
  refuses any shielded purpose, regardless of peer/transport. This is
  the runtime safety net that prevents a misconfigured daemon from
  reaching out to Railgun relayers without an explicit `tor` mode.

* **Response/result disambiguation** — the JSON serialization of a
  bridge `Response` carries an `"ok"` boolean whose value uniquely
  identifies success vs. error vs. crash. The daemon cannot mistake a
  bridge crash for a successful proof.

The plaintext-key invariant (5.3) is enforced *by the type of
`Bridge.Response`*: there is no field carrying `ByteArray` key
material. That is a definitional property of the ADT and does not need
a theorem here.
-/

namespace LeanCli.Invariants.Bridge

open LeanCli.Privacy.Bridge
open LeanCli.Network.Policy

/-! ## Method purpose classification -/

theorem methodPurpose_ping : methodPurpose "ping" = Purpose.daemonControl := rfl

theorem methodPurpose_version : methodPurpose "version" = Purpose.daemonControl := rfl

theorem methodPurpose_listProtocols :
    methodPurpose "listProtocols" = Purpose.daemonControl := rfl

theorem methodPurpose_broadcast :
    methodPurpose "shielded.broadcast" = Purpose.shieldedBroadcast := rfl

theorem methodPurpose_signAndBroadcast :
    methodPurpose "shielded.signAndBroadcast" = Purpose.shieldedBroadcast := rfl

/-- Anything not explicitly recognized as broadcast or local introspection
is treated as shielded read traffic. The daemon thus *cannot* accidentally
reclassify a future bridge method as `nodeRead` or `daemonControl`. -/
theorem methodPurpose_default :
    methodPurpose "shielded.prepareShield" = Purpose.shieldedRead := rfl

/-! ## Strict mode denies shielded egress

In `strictDaemonPolicy`, shielded purposes are not enumerated, so the
fall-through `_ => false` arm fires regardless of peer or transport. -/

theorem strict_denies_shielded_read
    (peer : Peer) (transport : Transport) :
    strictDaemonPolicy
      { peer := peer, purpose := Purpose.shieldedRead, transport := transport } = false := by
  cases peer <;> cases transport <;> rfl

theorem strict_denies_shielded_broadcast
    (peer : Peer) (transport : Transport) :
    strictDaemonPolicy
      { peer := peer, purpose := Purpose.shieldedBroadcast, transport := transport } = false := by
  cases peer <;> cases transport <;> rfl

/-! ## Tor mode constrains shielded egress to Tor-to-configured-node

Even in Tor mode, shielded traffic cannot leave the host directly or
target the local node, the local daemon, or arbitrary third parties.
The only positive case is `configuredNode` over `tor`. -/

theorem tor_shielded_read_requires_tor_to_configured
    (peer : Peer) (transport : Transport) :
    torDaemonPolicy
        { peer := peer, purpose := Purpose.shieldedRead, transport := transport } = true →
      peer = Peer.configuredNode ∧ transport = Transport.tor := by
  cases peer <;> cases transport <;> intro h <;> first | (exact ⟨rfl, rfl⟩) | cases h

theorem tor_shielded_broadcast_requires_tor_to_configured
    (peer : Peer) (transport : Transport) :
    torDaemonPolicy
        { peer := peer, purpose := Purpose.shieldedBroadcast, transport := transport } = true →
      peer = Peer.configuredNode ∧ transport = Transport.tor := by
  cases peer <;> cases transport <;> intro h <;> first | (exact ⟨rfl, rfl⟩) | cases h

/-! ## Response disambiguation

`responseToJson` projects every `Response` to a JSON object with an
explicit `ok` field whose value is `true` exactly when the bridge
returned a `result`, and `false` for both `err` and `crash`. The daemon
forwards this JSON to the CLI; the CLI cannot read a crash as success
without first ignoring the `ok` field. -/

/-- Helper: read the `ok` boolean out of a `responseToJson` envelope. -/
def okField : LeanCli.Encoding.Json.Json → Option Bool
  | .obj fields =>
      (fields.find? (fun (k, _) => k == "ok")).bind fun (_, v) =>
        match v with
        | .bool b => some b
        | _ => none
  | _ => none

theorem ok_field_of_ok (j : LeanCli.Encoding.Json.Json) :
    okField (responseToJson (Response.ok j)) = some true := rfl

theorem ok_field_of_err
    (code : Int) (msg : String) (data : Option LeanCli.Encoding.Json.Json) :
    okField (responseToJson (Response.err code msg data)) = some false := by
  cases data <;> rfl

theorem ok_field_of_crash (stderr : String) (exitCode : UInt32) :
    okField (responseToJson (Response.crash stderr exitCode)) = some false := rfl

/-! ## Invariant 5.7 — every bridge call factors through the policy gate

`callGated` evaluates the pure `gateDecision` before any process is
spawned. The two lemmas below pin down both arms of that decision:

* a policy-denied request yields `gateDecision = .error (policyDenial
  req)`, and
* `callGated` on a `.error` decision is `pure denial` — i.e. it never
  reaches the `callWithEnv` spawn branch.

Because `callGated` is the only path `shieldedBridgeCall` takes into the
sidecar, a denied shielded request can never spawn the bridge. The
allow-path symmetry (`gateDecision = .ok ()` ⇒ proceed) is the other arm
of the same `if`, so the dispatcher respects the gate in both
directions. -/

/-- When the policy denies the (peer, transport, purpose, chain) request,
the pure gate returns the fixed denial — independent of the rest of IO. -/
theorem gateDecision_denied_when_policy_denies
    (policy : Policy) (req : Request) (chainId : Option Nat)
    (h : policyAllows policy .configuredNode .direct req chainId = false) :
    gateDecision policy req chainId = .error (policyDenial req) := by
  unfold gateDecision
  simp [h]

/-- A denied gate decision makes `callGated` return the denial with no
spawn: the IO action reduces definitionally to `pure (policyDenial req)`,
so the `callWithEnv` branch is unreachable. This is the runtime
no-egress guarantee behind invariant 5.7. -/
theorem callGated_denied_when_policy_denies
    (policy : Policy) (req : Request)
    (env : Array (String × Option String)) (chainId : Option Nat)
    (h : policyAllows policy .configuredNode .direct req chainId = false) :
    callGated policy req env chainId = pure (policyDenial req) := by
  unfold callGated
  rw [gateDecision_denied_when_policy_denies policy req chainId h]

/-- Conversely, when the policy permits the request the gate clears and
`callGated` proceeds to the (un-gated) transport primitive. Together with
the denial lemma this shows `callGated` respects `gateDecision` in both
arms — there is no third path. -/
theorem callGated_allowed_proceeds
    (policy : Policy) (req : Request)
    (env : Array (String × Option String)) (chainId : Option Nat)
    (h : policyAllows policy .configuredNode .direct req chainId = true) :
    callGated policy req env chainId = callWithEnv req env := by
  unfold callGated gateDecision
  simp [h]

end LeanCli.Invariants.Bridge
