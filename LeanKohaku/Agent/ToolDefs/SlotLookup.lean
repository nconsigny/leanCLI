import LeanKohaku.Agent.Tools
import LeanKohaku.Agent.DaemonClient
import LeanKohaku.Agent.ToolDefs.TrustedRegistry
import LeanKohaku.Encoding.Json

/-!
# `slot_lookup` agent tool

Single-purpose lookup over the trusted-registry snapshot. The user
types `leanWallet/0` or `leanWallet/fresh1` and the model needs to
resolve that to a concrete 0x address without making a stochastic
guess between visually similar slots (`leanWallet/0` vs
`leanWallet/ops`).

The match is intentionally **case-sensitive** and on the rendered
slot name — the exact string the user typed in their prompt. Fuzzy
matching is the bug we're fixing here: a 4B-param model conflating
two similar slot names is precisely how the wrong address ends up
on the signing path. On miss we still return any prefix matches
under `nearestMatches` so the model can ask the user a useful
clarifying question rather than re-invent the slot.

Read-only by construction: this tool calls
`wallet.lean_verified_addresses` (the same RPC the trusted-registry
session cache uses) and never touches a signing primitive. No new
daemon RPC needed.
-/

namespace LeanKohaku.Agent.ToolDefs.SlotLookup

open LeanKohaku.Agent
open LeanKohaku.Agent.Tools
open LeanKohaku.Agent.DaemonClient
open LeanKohaku.Agent.ToolDefs.TrustedRegistry
open LeanKohaku.Encoding.Json

/-- Canonical name for an EOA entry. Mirrors `renderForPrompt`:
    `"{slot}/{label}"` when the entry has both, else just `{slot}`,
    else the path. Anything without a slot or path renders as `"?"`. -/
private def canonicalName (a : TrustedAddress) : String :=
  match a.slot, a.label, a.path with
  | some s, some l, _      => s!"{s}/{l}"
  | some s, none,   some p => s!"{s} @ {p}"
  | some s, none,   none   => s
  | none,   _,      some p => p
  | none,   _,      none   => "?"

/-- Render the entry's payload for a hit response. EOA and sphincs
    diverge slightly: sphincs carries the smart-account address under
    `address` already but also surfaces `ownerAddress` so the model
    can reason about who can sign. -/
private def renderHitData (slot : String) (a : TrustedAddress) : Json :=
  let common : Array (String × Json) := #[
    ("slot",    .str slot),
    ("address", .str a.address),
    ("kind",    .str a.kind)
  ]
  let extra : Array (String × Json) :=
    (match a.unlocked with
      | some b => #[("unlocked", .bool b)]
      | none   => #[]) ++
    (match a.path with
      | some p => #[("path", .str p)]
      | none   => #[]) ++
    (match a.label with
      | some l => #[("label", .str l)]
      | none   => #[]) ++
    (match a.ownerAddress with
      | some o => #[("ownerAddress", .str o)]
      | none   => #[])
  .obj (common ++ extra)

/-- Find entries whose canonical name starts with `query` (case-
    sensitive). Returns the list of canonical names. Used to fill the
    `nearestMatches` array on a miss so the model has something
    actionable to ask the user about instead of re-guessing. -/
private def prefixMatches (snap : Snapshot) (query : String) : List String :=
  snap.addresses.toList.filterMap fun a =>
    let n := canonicalName a
    if n.startsWith query ∧ n ≠ query then some n else none

/-- Single-entry registry lookup keyed by exact canonical name. -/
def slotLookup : ToolDecl := {
  name := "slot_lookup",
  description :=
    "Resolve a wallet slot name the user typed (e.g. \"leanWallet/0\", \
     \"leanWallet/fresh1\") to its exact 0x address. Match is \
     case-sensitive on the EXACT string — never assume \
     \"leanWallet/0\" and \"leanWallet/ops\" refer to the same \
     address. Returns kind:\"unknown_slot\" with optional \
     nearestMatches on a miss; ask the user rather than guess.",
  paramSchema := .obj #[
    ("type", .str "object"),
    ("required", .arr #[.str "name"]),
    ("properties", .obj #[
      ("name", .obj #[
        ("type", .str "string"),
        ("description",
          .str "Canonical slot name as the user typed it; e.g. \"leanWallet/0\"")
      ])
    ])
  ],
  classify := .read,
  invoke := fun cfg args => do
    let some nameJ := getField "name" args
      | pure {
          ok := false,
          data := .obj #[
            ("kind",  .str "bad_request"),
            ("error", .str "slot_lookup: missing 'name'")
          ]
        }
    let some name := asString nameJ
      | pure {
          ok := false,
          data := .obj #[
            ("kind",  .str "bad_request"),
            ("error", .str "slot_lookup: 'name' must be a string")
          ]
        }
    -- Pull a fresh snapshot through the same RPC the session cache
    -- uses. Cheap (read-only, no chain I/O) and avoids stale-cache
    -- weirdness when the daemon has rotated seeds mid-session.
    match ← fetchSnapshot cfg.daemonSocket
             defaultPaths 5 true with
    | .error e =>
        pure {
          ok := false,
          data := .obj #[
            ("kind",  .str "registry_error"),
            ("error", .str e)
          ]
        }
    | .ok snap =>
        match snap.addresses.toList.find? (fun a => canonicalName a == name) with
        | some hit =>
            pure {
              ok := true,
              data := renderHitData name hit,
              summary := some s!"{name} → {hit.address}"
            }
        | none =>
            let near := prefixMatches snap name
            let nearJson : Array Json := near.toArray.map (fun s => .str s)
            pure {
              ok := false,
              data := .obj #[
                ("kind",          .str "unknown_slot"),
                ("error",
                  .str s!"slot '{name}' not in trusted registry; ask the user"),
                ("suggest",
                  .str "list slots via trusted_registry_list"),
                ("nearestMatches", .arr nearJson)
              ]
            }
}

end LeanKohaku.Agent.ToolDefs.SlotLookup
