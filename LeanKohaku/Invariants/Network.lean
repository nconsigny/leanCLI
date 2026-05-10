import LeanKohaku.Cli.Commands
import LeanKohaku.Daemon.Config
import LeanKohaku.Network.Endpoint
import LeanKohaku.Network.Provider

/-!
# Network, endpoint, and daemon-command invariants

This file keeps the network/privacy proof surface together. The CLI is only
allowed to preflight local daemon requests; daemon/provider plans stay inside
the modeled network policy; endpoint hygiene rejects credentialed or
third-party surfaces.
-/

namespace LeanKohaku.Invariants.Network

open LeanKohaku.Cli.Commands
open LeanKohaku.Network.Endpoint
open LeanKohaku.Network.Provider
open LeanKohaku.Privacy.NetworkPolicy

theorem daemonRequestAlwaysLocal (action : Action) :
    (daemonRequest action).peer = Peer.localDaemon ∧
      (daemonRequest action).purpose = Purpose.daemonControl ∧
        (daemonRequest action).transport = Transport.loopback := by
  cases action <;> simp [daemonRequest]

theorem preflightImpliesValid (policy : Policy) (action : Action) :
    preflight policy action = true → action.valid = true := by
  intro h
  cases action <;> simp [preflight] at h ⊢
  · exact h.left
  · exact h.left

theorem preflightStrictCliImpliesLocalDaemon (action : Action) :
    preflight strictCliPolicy action = true →
      strictCliPolicy (daemonRequest action) = true := by
  intro h
  cases action <;> simp [preflight] at h ⊢
  · exact h.right
  · exact h.right

theorem parsedSendPositive (to amount : String) (action : Action) :
    parseSend to amount = some action →
      ∃ n, action = Action.send to n ∧ n > 0 := by
  intro h
  unfold parseSend at h
  cases hn : parsePositiveNat amount with
  | none =>
      simp [hn] at h
  | some n =>
      by_cases hv : (Action.send to n).valid
      · simp [hn, hv] at h
        subst h
        exists n
        exact ⟨rfl, parsePositiveNat_some_positive hn⟩
      · simp [hn, hv] at h

theorem balanceMapsToRead (address : String) :
    (providerOperation (Action.balance address)).method = RpcMethod.getBalance := by
  rfl

theorem sendMapsToBroadcast (to : String) (amountWei : Nat) :
    (providerOperation (Action.send to amountWei)).method = RpcMethod.sendRawTransaction := by
  rfl

theorem strictPlanUsesLocalBackend (req : DaemonRequest) :
    match strictPlan req with
    | .provider cfg _ => cfg.backend = Backend.localNode ∧ cfg.transport = Transport.loopback := by
  cases req with
  | mk action =>
    cases action <;> simp [strictPlan, Config.local]

theorem strictPlanPermitted (req : DaemonRequest) :
    strictPermitted req = true := by
  cases req with
  | mk action =>
    cases action <;>
      simp [strictPermitted, strictPlan, planPermitted, providerOperation,
        Config.local, permitted, requestFor, peerFor, RpcMethod.purpose,
        strictDaemonPolicy]

theorem torPlanUsesConfiguredTor (req : DaemonRequest) :
    match torPlan req with
    | .provider cfg _ => cfg.backend = Backend.configuredNode ∧ cfg.transport = Transport.tor := by
  cases req with
  | mk action =>
    cases action <;> simp [torPlan, Config.torConfigured]

theorem torPlanPermitted (req : DaemonRequest) :
    torPermitted req = true := by
  cases req with
  | mk action =>
    cases action <;>
      simp [torPermitted, torPlan, planPermitted, providerOperation,
        Config.torConfigured, permitted, requestFor, peerFor,
        RpcMethod.purpose, torDaemonPolicy]

theorem acceptedStrictNoCredentials (ep : Endpoint) :
    acceptedStrict ep = true → ep.credentialed = false := by
  intro h
  cases ep with
  | mk kind scheme transport credentialed =>
    cases kind <;> cases scheme <;> cases transport <;> cases credentialed <;>
      simp [acceptedStrict] at h ⊢

theorem acceptedTorNoCredentials (ep : Endpoint) :
    acceptedTor ep = true → ep.credentialed = false := by
  intro h
  cases ep with
  | mk kind scheme transport credentialed =>
    cases kind <;> cases scheme <;> cases transport <;> cases credentialed <;>
      simp [acceptedTor] at h ⊢

theorem acceptedStrictLocalOnly (ep : Endpoint) :
    acceptedStrict ep = true → ep.kind = EndpointKind.local ∧ ep.transport = Transport.loopback := by
  intro h
  cases ep with
  | mk kind scheme transport credentialed =>
    cases kind <;> cases scheme <;> cases transport <;> cases credentialed <;>
      simp [acceptedStrict] at h ⊢

theorem acceptedTorNeverThirdParty (ep : Endpoint) :
    acceptedTor ep = true → ep.kind ≠ EndpointKind.thirdParty := by
  intro h
  cases ep with
  | mk kind scheme transport credentialed =>
    cases kind <;> cases scheme <;> cases transport <;> cases credentialed <;>
      simp [acceptedTor] at h ⊢

theorem configuredTorAccepted :
    acceptedTor Endpoint.configuredTor = true := by
  rfl

theorem defaultLocalStrictAccepted :
    acceptedStrict Endpoint.defaultLocal = true := by
  rfl

theorem strictCli_onlyLocalDaemon (req : NetworkRequest) :
    strictCliPolicy req = true →
      req.peer = Peer.localDaemon ∧
        req.purpose = Purpose.daemonControl ∧
          req.transport = Transport.loopback := by
  cases req with
  | mk peer purpose transport =>
    cases peer <;> cases purpose <;> cases transport <;> simp [strictCliPolicy]

theorem strictDaemon_neverThirdParty (req : NetworkRequest) :
    strictDaemonPolicy req = true → req.peer ≠ Peer.thirdPartyApi := by
  cases req with
  | mk peer purpose transport =>
    cases peer <;> cases purpose <;> cases transport <;> simp [strictDaemonPolicy]

theorem torDaemon_neverThirdParty (req : NetworkRequest) :
    torDaemonPolicy req = true → req.peer ≠ Peer.thirdPartyApi := by
  cases req with
  | mk peer purpose transport =>
    cases peer <;> cases purpose <;> cases transport <;> simp [torDaemonPolicy]

theorem strictDaemon_noConfiguredNode (req : NetworkRequest) :
    strictDaemonPolicy req = true → req.peer ≠ Peer.configuredNode := by
  cases req with
  | mk peer purpose transport =>
    cases peer <;> cases purpose <;> cases transport <;> simp [strictDaemonPolicy]

theorem torDaemon_configuredNodeOnlyTor (req : NetworkRequest) :
    torDaemonPolicy req = true →
      req.peer = Peer.configuredNode →
        req.transport = Transport.tor := by
  cases req with
  | mk peer purpose transport =>
    cases peer <;> cases purpose <;> cases transport <;> simp [torDaemonPolicy]

theorem deniedThirdPartyPurposesStrict (req : NetworkRequest) :
    thirdPartyPurpose req.purpose = true →
      strictDaemonPolicy req = false := by
  cases req with
  | mk peer purpose transport =>
    cases peer <;> cases purpose <;> cases transport <;> simp [thirdPartyPurpose, strictDaemonPolicy]

theorem nonBroadcastMethodsAreReads (m : RpcMethod) :
    m ≠ RpcMethod.sendRawTransaction → m.purpose = Purpose.nodeRead := by
  intro h
  cases m <;> simp [RpcMethod.purpose] at *

theorem strictConfiguredProviderDenied (cfg : Config) (op : Operation) :
    permitted strictDaemonPolicy cfg op = true →
      cfg.backend ≠ Backend.configuredNode := by
  intro h
  cases cfg with
  | mk backend transport =>
    cases op with
    | mk method params =>
      cases backend <;> cases transport <;> cases method <;>
        simp [permitted, requestFor, peerFor, RpcMethod.purpose, strictDaemonPolicy] at h ⊢

theorem torConfiguredProviderOnlyTor (cfg : Config) (op : Operation) :
    permitted torDaemonPolicy cfg op = true →
      cfg.backend = Backend.configuredNode →
        cfg.transport = Transport.tor := by
  intro h backendEq
  cases cfg with
  | mk backend transport =>
    cases op with
    | mk method params =>
      cases backend <;> cases transport <;> cases method <;>
        simp [permitted, requestFor, peerFor, RpcMethod.purpose, torDaemonPolicy] at h backendEq ⊢

theorem denyByDefault_denies (req : NetworkRequest) :
    denyByDefault req = false := by
  simp [denyByDefault]

/-! ## Per-chain RPC URL precedence (`pickChainUrl`)

Pure model for `Daemon.Config.pickChainUrl`. Persisted (`daemon.json`) wins
over both env forms; the namespaced env var (`LEANKOHAKU_RPC_URL_<UPPER>`)
wins over the generic `<UPPER>_RPC_URL`. This rules out a regression where a
stale env value silently overrides explicit user config or the legacy generic
form shadows the leanKohaku-namespaced one. -/

open LeanKohaku.Daemon.Config in
theorem pickChainUrl_persisted_wins (p ns gen : String) :
    pickChainUrl (some p) (some ns) (some gen) = some (p, ChainUrlSource.persisted) := by
  rfl

open LeanKohaku.Daemon.Config in
theorem pickChainUrl_namespaced_beats_generic (ns gen : String) :
    pickChainUrl none (some ns) (some gen) = some (ns, ChainUrlSource.namespaced) := by
  rfl

open LeanKohaku.Daemon.Config in
theorem pickChainUrl_generic_only (gen : String) :
    pickChainUrl none none (some gen) = some (gen, ChainUrlSource.generic) := by
  rfl

open LeanKohaku.Daemon.Config in
theorem pickChainUrl_none_when_unset :
    pickChainUrl none none none = none := by
  rfl

end LeanKohaku.Invariants.Network
