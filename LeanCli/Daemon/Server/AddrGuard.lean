import LeanCli.Daemon.AddressIntegrity
import LeanCli.Daemon.Server.Helpers
import LeanCli.Wallet.EoaStore
import LeanCli.Wallet.SphincsHybridStore
import LeanCli.RPC.Server
import LeanCli.Encoding.Json

/-!
# Address-integrity sign-time gate (IO wrapper)

Gathers the addresses the daemon actually knows (EOA slots + their
sub-accounts, SPHINCS hybrid smart-accounts + their owners) and runs the
pure `AddressIntegrity.check` against a proposal's calldata just before
signing. A near-miss to a known address — the signature of an LLM-typo'd
spender/recipient — is refused with a "did you mean …?" RPC error rather
than signed. The caller may override with `acknowledgeAddressWarnings:
true` once the user has knowingly confirmed the unusual address.

This is the enforcement point referenced by the `eoa.send` /
`sphincs.account.send` pre-sign guards; it sits next to the existing
`isNoOpCall` check.
-/

namespace LeanCli.Daemon.Server.AddrGuard

open LeanCli.Encoding.Json
open LeanCli.RPC.Server
open LeanCli.Daemon.AddressIntegrity

/-- Nibble-distance ceiling for "this is a typo of a known address". A
transposition differs in 2 positions and a single fat-finger in 1; an
intended unrelated address differs in ~37 of 40, so 4 cleanly separates
typos from legitimate distinct addresses. -/
def threshold : Nat := 4

/-- Every address the daemon itself controls — the set a corrupted
address most likely *meant*. Best-effort: store-read failures are skipped,
never fatal (the gate must not break sending). -/
def gatherKnownAddresses : IO (List (String × String)) := do
  let mut acc : List (String × String) := []
  let eoaNames ← LeanCli.Wallet.EoaStore.list
  for name in eoaNames do
    match ← LeanCli.Wallet.EoaStore.load name with
    | .ok rec =>
        for a in LeanCli.Daemon.Server.recordAccounts rec do
          acc := (a.address, s!"{rec.name}/{a.index}") :: acc
    | .error _ => pure ()
  try
    let sphNames ← LeanCli.Wallet.SphincsHybridStore.listSlotNames
    for name in sphNames do
      match ← LeanCli.Wallet.SphincsHybridStore.readRecord name with
      | .ok rec =>
          match rec.smartAccountAddress with
          | some sa => acc := (sa, rec.name) :: acc
          | none    => pure ()
          acc := (rec.ownerAddress, s!"{rec.name} owner") :: acc
      | .error _ => pure ()
  catch _ => pure ()
  pure acc

private def warningsJson (ws : List Warning) : Json :=
  .arr ((ws.map (fun w => .obj #[
    ("field",     .str w.field),
    ("got",       .str w.got),
    ("suspected", .str w.suspect),
    ("label",     .str w.label),
    ("distance",  .num (Int.ofNat w.distance))
  ])).toArray)

/-- Pre-sign address-integrity gate. `.ok ()` when the calldata is clean
or the caller explicitly acknowledged the warnings; `.error` (refuse to
sign) when an embedded address is a near-miss to a known address. -/
def enforce (params : Json) (to dataHex : String) : IO (Except RpcError Unit) := do
  let acked := match getField "acknowledgeAddressWarnings" params with
    | some (.bool b) => b
    | _              => false
  if acked then return .ok ()
  let known ← gatherKnownAddresses
  let ws := check known to dataHex threshold
  match ws with
  | [] => return .ok ()
  | w :: _ =>
      return .error {
        code := -32060,
        message :=
          s!"refusing to sign: {w.field} address {w.got} looks like a typo of {w.label} — did you mean {w.suspect}? (differs by {w.distance} hex digit(s)). Re-resolve the address, or pass acknowledgeAddressWarnings:true to override.",
        data := some (.obj #[("addressWarnings", warningsJson ws)])
      }

end LeanCli.Daemon.Server.AddrGuard
