import LeanCli.Daemon.State
import LeanCli.RPC.Outbound
import LeanCli.Privacy.NetworkPolicy
import LeanCli.Crypto.Hex

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

namespace LeanCli.Daemon.TokenMeta

open LeanCli.Crypto

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
def lookup (state : LeanCli.Daemon.State.Shared) (chainId : Nat) (address : String) :
    IO (Option TokenMeta) := do
  let key := metaKey chainId address
  let s ← state.get
  pure <| (s.tokenMeta.find? (fun (k, _) => k == key)).map
    (fun (_, (d, sym)) => { decimals := d, symbol := sym })

/-- Insert/overwrite a cache entry. -/
def setMeta (state : LeanCli.Daemon.State.Shared) (chainId : Nat) (address : String)
    (m : TokenMeta) : IO Unit := do
  let key := metaKey chainId address
  let entry : LeanCli.Daemon.State.TokenMetaEntry := (m.decimals, m.symbol)
  state.modify (fun s =>
    let filtered := s.tokenMeta.filter (fun (k, _) => k != key)
    { s with tokenMeta := filtered ++ [(key, entry)] })

/-- Fetch decimals + symbol for `address` via `eth_call`, cache, return.
    On any failure (RPC error, decode failure, policy denial) returns `none`
    silently — the caller falls back to address-only display. -/
def fetchAndCache
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Privacy.NetworkPolicy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (chainId : Nat) (address : String) : IO (Option TokenMeta) := do
  -- Route through Colibri when the persistent client is up so token
  -- metadata reads are committee-verified, same as balances/calls. Uses
  -- the shared respawn-on-transport-crash policy via `buildColibriVia`.
  let via? ← LeanCli.Daemon.State.buildColibriVia state chainId
  let decRes ← LeanCli.RPC.Outbound.ethCall policy endpoint address decimalsSelector "latest" via?
  let symRes ← LeanCli.RPC.Outbound.ethCall policy endpoint address symbolSelector "latest" via?
  match decRes, symRes with
  | .ok decJson, .ok symJson =>
      let decHex := (LeanCli.Encoding.Json.asString decJson).getD ""
      let symHex := (LeanCli.Encoding.Json.asString symJson).getD ""
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
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Privacy.NetworkPolicy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (chainId : Nat) (address : String) : IO (Option TokenMeta) := do
  match ← lookup state chainId address with
  | some m => pure (some m)
  | none => fetchAndCache state policy endpoint chainId address

/-- Render a `TokenMeta` as JSON for the bridge call. -/
def toJson (m : TokenMeta) : LeanCli.Encoding.Json.Json :=
  .obj #[
    ("decimals", .num (Int.ofNat m.decimals)),
    ("symbol",   .str m.symbol)
  ]

end LeanCli.Daemon.TokenMeta
