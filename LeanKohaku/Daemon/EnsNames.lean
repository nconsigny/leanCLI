import LeanKohaku.Encoding.Json

/-!
# ENS namehash → name session cache

Threaded through `tx.decodeIntent` so the clearsign sidecar's
`ensName` formatter can render `bytes32 node` arguments on
PublicResolver calls as human-readable names instead of opaque hex.

## Trust contract

* This cache is **display-only**. The clearsign formatter falls back
  to short-hex with "(unresolved name)" when a namehash isn't in the
  cache, never to a wrong name. No signing decision reads from this.
* Population is conservative: only namehashes the wallet has
  produced or observed itself land here. We deliberately don't query
  a third-party subgraph in this MVP — that's a follow-up gated on
  `NetworkPolicy`, mirroring the chain-read policy.
* The cache is daemon-lifetime in-memory. Survives across RPCs from
  the same session; lost on daemon restart. SQLite persistence is a
  follow-up.

## Population paths (today)

* Manual `record` from the call sites that produce a name + namehash
  pair. Hooked from ENS controller flow (when the wallet drafts a
  `register`/`renew` we'll have both fields and can store).
* `recordPair` for cold injection from offline tools.

Future: a `chain.ensReverseLookup` RPC that calls the ENS reverse
resolver via the existing chain-read path; result lands here.

## Shape

`forCalldata` returns a `Json.obj` of `{ "<0x-namehash>" : "<name>" }`
keyed by lowercased hex, ready to merge into the `ensNames` field the
sidecar (`bridge/clearsign/src/decoder.mjs`) consumes.
-/

namespace LeanKohaku.Daemon.EnsNames

open LeanKohaku.Encoding.Json

/-- In-memory cache. List-of-pairs because the daemon cache is
short-lived per session and namehash lookups happen at most once per
field per `tx.decodeIntent`; a linear scan is fine and we avoid a
dependency on Lean 4 v4.29.1's still-moving `Std.HashMap`. Keys are
lowercased `0x`-prefixed namehashes; values are the corresponding ENS
names (e.g. `"vitalik.eth"`). -/
abbrev Cache : Type := List (String × String)

/-- Empty cache. Daemon constructs one per session. -/
def emptyCache : Cache := []

/-- Record a `(namehash, name)` pair into the cache. Drops any prior
entry at the same key so a re-record overwrites cleanly. -/
def recordPair (c : Cache) (namehashHex : String) (name : String) : Cache :=
  let key := namehashHex.toLower
  (key, name) :: c.filter (fun p => p.1 ≠ key)

/-- Look up a name by namehash. Case-insensitive on the key. -/
def lookup? (c : Cache) (namehashHex : String) : Option String :=
  let key := namehashHex.toLower
  (c.find? (fun p => p.1 == key)).map Prod.snd

/-- Render the current cache as the `ensNames` JSON object the sidecar
expects. Keys are already lowercased in `recordPair`; the formatter's
lookup matches regardless of the descriptor's source casing.

This is a **display-only** payload: the formatter renders missing
keys as raw short-hex with an "(unresolved name)" suffix, so an empty
cache is safe to forward. -/
def toJson (c : Cache) : Json :=
  .obj (c.toArray.map (fun ⟨k, v⟩ => (k, Json.str v)))

/-- Stub: derive `ensNames` for a given `tx.decodeIntent` request.
For now returns whatever's already cached; future work will scan
calldata for `bytes32 node` args and try to resolve each via the
chain-read path before answering. -/
def forDecodeRequest (c : Cache) (_chainId : Nat) (_to : String) (_data : String)
    : Json :=
  toJson c

end LeanKohaku.Daemon.EnsNames
