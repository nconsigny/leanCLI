import LeanKohaku.Daemon.State
import LeanKohaku.RPC.Outbound
import LeanKohaku.Privacy.NetworkPolicy
import LeanKohaku.Crypto.Hex

/-!
# ERC-20 token metadata cache

Daemon-side cache of `(chainId, address) → {decimals, symbol}` populated via
`eth_call(decimals())` and `eth_call(symbol())`. Used by `tx.decodeIntent`
to render `tokenAmount` fields with real decimals + ticker instead of the
short-address placeholder fallback.

The cache is process-scoped: it survives wallet locks but not daemon
restarts. Misses are rare in practice (a few dozen tokens per user) so a
flat `List` is fast enough; refactor to a `HashMap` if it ever matters.

Reads are always policy-gated through `RPC.Outbound.ethCall`. Failures fall
back silently — the bridge's `tokenAmount` formatter handles missing
metadata by rendering the raw scalar with a short-address tag.
-/

namespace LeanKohaku.Daemon.TokenMeta

open LeanKohaku.Crypto

structure TokenMeta where
  decimals : Nat
  symbol   : String
  deriving Repr

/-- Cache key. Lowercased address ensures EIP-55 vs lowercase forms hit the
    same entry. -/
def metaKey (chainId : Nat) (address : String) : String :=
  s!"{chainId}:{address.toLower}"

/-- ERC-20 ABI selectors (function-name → keccak[0..4]). -/
def decimalsSelector : String := "0x313ce567"
def symbolSelector   : String := "0x95d89b41"

private def take (bytes : ByteArray) (start len : Nat) : ByteArray :=
  (List.range len).foldl
    (init := ByteArray.empty)
    (fun acc i => if h : start + i < bytes.size then acc.push (bytes.get! (start + i)) else acc)

private def bytesToNat (bytes : ByteArray) : Nat :=
  bytes.foldl (init := 0) (fun acc byte => acc * 256 + byte.toNat)

/-- Decode an ABI return for `decimals()`: a uint8 right-padded to 32 bytes.
    Returns `none` on malformed input. -/
def decodeDecimalsReturn (hex : String) : Option Nat := do
  let bytes ← Hex.decode (hex.dropPrefix "0x").toString
  if bytes.size < 32 then none
  else
    let n := bytesToNat (take bytes 0 32)
    -- Sanity: ERC-20 decimals never exceeds 255, but tokens have shipped 18
    -- as the ceiling in practice. Reject anything obviously bogus rather
    -- than render "0.<huge>" amounts.
    if n > 64 then none else some n

/-- Decode an ABI return for `symbol()`. Most modern tokens return dynamic
    `string`; some legacy tokens (MKR-era) return `bytes32`. We support
    both: if the first 32-byte word is exactly `0x20` (offset to data) we
    interpret as `string`; otherwise as `bytes32` with trailing-null trim. -/
def decodeSymbolReturn (hex : String) : Option String := do
  let bytes ← Hex.decode (hex.dropPrefix "0x").toString
  if bytes.size < 32 then none
  else
    let firstWord := bytesToNat (take bytes 0 32)
    if firstWord = 32 && bytes.size ≥ 64 then
      let len := bytesToNat (take bytes 32 32)
      if len > 64 then none  -- guard against runaway
      else
        let payload := take bytes 64 (min len (bytes.size - 64))
        String.fromUTF8? payload
    else
      -- bytes32: trim trailing nulls from the leading 32-byte word.
      let trimmed := (take bytes 0 32).toList.foldr
        (init := []) (fun b acc =>
          if acc.isEmpty && b == 0 then [] else b :: acc)
        |>.toByteArray
      String.fromUTF8? trimmed

/-- Cache lookup. Returns `none` if not yet fetched. -/
def lookup (state : LeanKohaku.Daemon.State.Shared) (chainId : Nat) (address : String) :
    IO (Option TokenMeta) := do
  let key := metaKey chainId address
  let s ← state.get
  pure <| (s.tokenMeta.find? (fun (k, _) => k == key)).map
    (fun (_, (d, sym)) => { decimals := d, symbol := sym })

/-- Insert/overwrite a cache entry. -/
def setMeta (state : LeanKohaku.Daemon.State.Shared) (chainId : Nat) (address : String)
    (m : TokenMeta) : IO Unit := do
  let key := metaKey chainId address
  let entry : LeanKohaku.Daemon.State.TokenMetaEntry := (m.decimals, m.symbol)
  state.modify (fun s =>
    let filtered := s.tokenMeta.filter (fun (k, _) => k != key)
    { s with tokenMeta := filtered ++ [(key, entry)] })

/-- Fetch decimals + symbol for `address` via `eth_call`, cache, return.
    On any failure (RPC error, decode failure, policy denial) returns `none`
    silently — the caller falls back to address-only display. -/
def fetchAndCache
    (state : LeanKohaku.Daemon.State.Shared)
    (policy : LeanKohaku.Privacy.NetworkPolicy.Policy)
    (endpoint : LeanKohaku.RPC.Outbound.Endpoint)
    (chainId : Nat) (address : String) : IO (Option TokenMeta) := do
  -- Route through Colibri when the persistent client is up so token
  -- metadata reads are committee-verified, same as balances/calls. Uses
  -- the shared respawn-on-transport-crash policy via `buildColibriVia`.
  let via? ← LeanKohaku.Daemon.State.buildColibriVia state chainId
  let decRes ← LeanKohaku.RPC.Outbound.ethCall policy endpoint address decimalsSelector "latest" via?
  let symRes ← LeanKohaku.RPC.Outbound.ethCall policy endpoint address symbolSelector "latest" via?
  match decRes, symRes with
  | .ok decJson, .ok symJson =>
      let decHex := (LeanKohaku.Encoding.Json.asString decJson).getD ""
      let symHex := (LeanKohaku.Encoding.Json.asString symJson).getD ""
      match decodeDecimalsReturn decHex, decodeSymbolReturn symHex with
      | some decimals, some symbol =>
          let m : TokenMeta := { decimals, symbol }
          setMeta state chainId address m
          pure (some m)
      | _, _ => pure none
  | _, _ => pure none

/-- Cache-or-fetch. Always returns the cached value when present; misses
    are filled via `fetchAndCache`. Idempotent. -/
def lookupOrFetch
    (state : LeanKohaku.Daemon.State.Shared)
    (policy : LeanKohaku.Privacy.NetworkPolicy.Policy)
    (endpoint : LeanKohaku.RPC.Outbound.Endpoint)
    (chainId : Nat) (address : String) : IO (Option TokenMeta) := do
  match ← lookup state chainId address with
  | some m => pure (some m)
  | none => fetchAndCache state policy endpoint chainId address

/-- Render a `TokenMeta` as JSON for the bridge call. -/
def toJson (m : TokenMeta) : LeanKohaku.Encoding.Json.Json :=
  .obj #[
    ("decimals", .num (Int.ofNat m.decimals)),
    ("symbol",   .str m.symbol)
  ]

/-- Fetch decimals + symbol over **direct RPC** (never Colibri) with the two
    `eth_call`s issued concurrently, returning the decoded `TokenMeta` WITHOUT
    touching the cache. Used by `batchLookupJson` where many tokens are fetched
    in parallel: the cache write (`setMeta` → `state.modify`) is not safe to run
    from worker threads, so we keep fetching pure and let the joining loop cache
    serially. `via? := none` mirrors `swap.balances`, which deliberately keeps
    fan-out off the single shared Colibri UDS. Token metadata is display-only
    (it renders decimals/ticker), so the non-verified read path is appropriate. -/
def fetchOnlyDirect
    (policy : LeanKohaku.Privacy.NetworkPolicy.Policy)
    (endpoint : LeanKohaku.RPC.Outbound.Endpoint)
    (_chainId : Nat) (address : String) : IO (Option TokenMeta) := do
  let decTask ← IO.asTask
    (LeanKohaku.RPC.Outbound.ethCall policy endpoint address decimalsSelector "latest" none)
  let symTask ← IO.asTask
    (LeanKohaku.RPC.Outbound.ethCall policy endpoint address symbolSelector "latest" none)
  let decR ← IO.wait decTask
  let symR ← IO.wait symTask
  match decR, symR with
  | .ok (.ok decJson), .ok (.ok symJson) =>
      let decHex := (LeanKohaku.Encoding.Json.asString decJson).getD ""
      let symHex := (LeanKohaku.Encoding.Json.asString symJson).getD ""
      match decodeDecimalsReturn decHex, decodeSymbolReturn symHex with
      | some decimals, some symbol => pure (some { decimals, symbol })
      | _, _ => pure none
  | _, _ => pure none

/-- Resolve metadata for a batch of addresses, returning
    `(lowercasedAddress, toJson meta)` pairs for every address that resolves.
    Deduplicates by lowercased address. Cache hits are read serially (cheap);
    misses are fetched **concurrently** (one task per token, each fetching
    decimals ∥ symbol) then cached serially on join — `setMeta` mutates shared
    state and must not run on worker threads. This replaces the per-token
    serial `lookupOrFetch` loops in `tx.simulate` (trace) and `tx.decodeIntent`,
    collapsing `2·K` sequential `eth_call`s into one round-trip's worth of wall
    time. Failures are dropped silently, exactly like the loops it replaces. -/
def batchLookupJson
    (state : LeanKohaku.Daemon.State.Shared)
    (policy : LeanKohaku.Privacy.NetworkPolicy.Policy)
    (endpoint : LeanKohaku.RPC.Outbound.Endpoint)
    (chainId : Nat) (addresses : Array String) :
    IO (Array (String × LeanKohaku.Encoding.Json.Json)) := do
  -- Dedup, first-seen order (output is a JSON map so order is cosmetic).
  let mut order : Array String := #[]
  let mut seen : Array String := #[]
  for raw in addresses do
    let lo := raw.toLower
    unless seen.contains lo do
      seen := seen.push lo
      order := order.push raw
  -- Cache hits resolved inline; misses spawned as concurrent fetch tasks.
  let mut out : Array (String × LeanKohaku.Encoding.Json.Json) := #[]
  let mut tasks : Array (String × Task (Except IO.Error (Option TokenMeta))) := #[]
  for raw in order do
    match ← lookup state chainId raw with
    | some m => out := out.push (raw.toLower, toJson m)
    | none =>
        let t ← IO.asTask (fetchOnlyDirect policy endpoint chainId raw)
        tasks := tasks.push (raw, t)
  -- Join misses; cache + accumulate serially.
  for (raw, t) in tasks do
    match ← IO.wait t with
    | .ok (some m) =>
        setMeta state chainId raw m
        out := out.push (raw.toLower, toJson m)
    | _ => pure ()
  pure out

end LeanKohaku.Daemon.TokenMeta
