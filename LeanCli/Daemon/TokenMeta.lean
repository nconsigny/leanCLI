import LeanCli.Daemon.State
import LeanCli.RPC.Outbound
import LeanCli.Network.Policy
import LeanCli.Crypto.Hex
import LeanCli.Ethereum.Multicall3

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

/-- In-memory-only insert (no vault write). Used to hydrate the process
    cache from a vault hit without re-recording provenance. -/
private def setMetaMemory (state : LeanCli.Daemon.State.Shared) (chainId : Nat)
    (address : String) (m : TokenMeta) : IO Unit := do
  let key := metaKey chainId address
  let entry : LeanCli.Daemon.State.TokenMetaEntry := (m.decimals, m.symbol)
  state.modify (fun s =>
    let filtered := s.tokenMeta.filter (fun (k, _) => k != key)
    { s with tokenMeta := filtered ++ [(key, entry)] })

/-- Cache lookup: process memory first, then the persistent StateVault
    (hydrating memory on a vault hit so the disk read is paid once per
    daemon lifetime). Returns `none` if never fetched. -/
def lookup (state : LeanCli.Daemon.State.Shared) (chainId : Nat) (address : String) :
    IO (Option TokenMeta) := do
  let key := metaKey chainId address
  let s ← state.get
  match (s.tokenMeta.find? (fun (k, _) => k == key)).map
      (fun (_, (d, sym)) => ({ decimals := d, symbol := sym } : TokenMeta)) with
  | some m => pure (some m)
  | none =>
      match ← LeanCli.Daemon.State.withVault state
          (fun h => LeanCli.Daemon.StateVault.getTokenMeta h chainId address) with
      | some (some (d, sym, _tier)) =>
          let m : TokenMeta := { decimals := d, symbol := sym }
          setMetaMemory state chainId address m
          pure (some m)
      | _ => pure none

/-- Insert/overwrite a cache entry, recording provenance in the vault.
    `tier` is the trust tier of the read that produced `m` (see
    `StateVault.tierOfVia`); the vault applies its no-downgrade rule. -/
def setMeta (state : LeanCli.Daemon.State.Shared) (chainId : Nat) (address : String)
    (m : TokenMeta) (tier : LeanCli.Daemon.StateVault.Tier) : IO Unit := do
  setMetaMemory state chainId address m
  let _ ← LeanCli.Daemon.State.withVault state
    (fun h => LeanCli.Daemon.StateVault.putTokenMeta h chainId address
      m.decimals m.symbol tier)
  pure ()

/-- Fetch decimals + symbol for `address` via `eth_call`, cache, return.
    On any failure (RPC error, decode failure, policy denial) returns `none`
    silently — the caller falls back to address-only display. -/
def fetchAndCache
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (chainId : Nat) (address : String) (direct : Bool := false) : IO (Option TokenMeta) := do
  -- Route through the daemon's *selected* read backend (helios/colibri/rpc)
  -- so metadata reads are verified by the same provider as the simulate —
  -- not hardwired to colibri. `endpoint.url` is the helios executionRpc.
  --
  -- `direct := true` bypasses the verified backend for DISPLAY-ONLY callers
  -- (e.g. `defi.positions`): the light client mis-serves some ERC-20 views
  -- (it returned wrong `decimals()` for GHO, so a 309-GHO debt rendered as
  -- "<0.01"), and metadata never reaches a signing decision on that path.
  -- The signing path (`decodeIntent → ConfirmGate`) keeps the verified read.
  let via? ← if direct then pure none
             else LeanCli.Daemon.State.buildVerifiedReadVia state chainId endpoint.url
  let decRes ← LeanCli.RPC.Outbound.ethCall policy endpoint address decimalsSelector "latest" via?
  let symRes ← LeanCli.RPC.Outbound.ethCall policy endpoint address symbolSelector "latest" via?
  match decRes, symRes with
  | .ok decJson, .ok symJson =>
      let decHex := (LeanCli.Encoding.Json.asString decJson).getD ""
      let symHex := (LeanCli.Encoding.Json.asString symJson).getD ""
      match decodeDecimalsReturn decHex, decodeSymbolReturn symHex with
      | some decimals, some symbol =>
          let m : TokenMeta := { decimals, symbol }
          setMeta state chainId address m (LeanCli.Daemon.StateVault.tierOfVia via?)
          pure (some m)
      | _, _ => pure none
  | _, _ => pure none

/-- Negative-cache lookup: has `address` already been observed to have no
    contract code on `chainId`? Memory first, then the vault (hydrating
    memory on a hit). -/
def isKnownNoCode (state : LeanCli.Daemon.State.Shared) (chainId : Nat)
    (address : String) : IO Bool := do
  let key := metaKey chainId address
  if (← state.get).noCodeAddrs.contains key then
    return true
  match ← LeanCli.Daemon.State.withVault state
      (fun h => LeanCli.Daemon.StateVault.isNoCode h chainId address) with
  | some true =>
      state.modify (fun s =>
        if s.noCodeAddrs.contains key then s
        else { s with noCodeAddrs := key :: s.noCodeAddrs })
      pure true
  | _ => pure false

/-- Record that `address` has no contract code, so future decodes skip it. -/
def markNoCode (state : LeanCli.Daemon.State.Shared) (chainId : Nat)
    (address : String) : IO Unit := do
  let key := metaKey chainId address
  state.modify (fun s =>
    if s.noCodeAddrs.contains key then s
    else { s with noCodeAddrs := key :: s.noCodeAddrs })
  let _ ← LeanCli.Daemon.State.withVault state
    (fun h => LeanCli.Daemon.StateVault.putNoCode h chainId address)
  pure ()

/-- Batched cache-or-fetch for *speculative* candidates (addresses scanned
    out of calldata by `scanCalldataAddresses`, many of which are misaligned
    junk or EOAs) via ONE Multicall3 `aggregate3` eth_call, routed through
    the same verified read backend as any other metadata read. On the
    light-client provider each verified eth_call is a full REVM run over the
    mutex-serialized shared connection, so the previous per-candidate
    pattern (getCode gate + decimals + symbol = up to 3 serial calls each)
    dominated `tx.decodeIntent` latency; the batch is one round-trip
    regardless of N.

    Junk self-selects out inside the batch (`allowFailure := true`): a
    reverting candidate comes back `success = false`, an EOA succeeds with
    empty return data and fails ABI decode — both land in the negative
    cache, so later decodes skip them without any RPC. Only a candidate
    whose `decimals()` AND `symbol()` both succeed and decode is cached as
    a token. On a batch-level failure (policy denial / transport /
    malformed return) every miss reports `none` and nothing is cached —
    the same silent-degradation rule as `fetchAndCache`.

    Returns one `(lowercased address, meta?)` entry per distinct input
    address (deduped on the cache-key form). -/
def lookupOrFetchBatch
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (chainId : Nat) (addresses : Array String) :
    IO (Array (String × Option TokenMeta)) := do
  let mut uniq : Array String := #[]
  for a in addresses do
    let lo := a.toLower
    if !uniq.contains lo then uniq := uniq.push lo
  let mut out : Array (String × Option TokenMeta) := #[]
  let mut misses : Array String := #[]
  for lo in uniq do
    match ← lookup state chainId lo with
    | some m => out := out.push (lo, some m)
    | none =>
        if ← isKnownNoCode state chainId lo then
          out := out.push (lo, none)
        else
          misses := misses.push lo
  if misses.isEmpty then
    return out
  -- Two calls per miss, in input order: decimals() then symbol().
  let calls : List LeanCli.Ethereum.Multicall3.Call3 :=
    misses.foldl (init := []) fun acc a =>
      acc ++ [ { target := a, allowFailure := true, callData := decimalsSelector },
               { target := a, allowFailure := true, callData := symbolSelector } ]
  let batchData := LeanCli.Ethereum.Multicall3.encodeAggregate3 calls
  let via? ← LeanCli.Daemon.State.buildVerifiedReadVia state chainId endpoint.url
  match ← LeanCli.RPC.Outbound.ethCall policy endpoint
      LeanCli.Ethereum.Multicall3.address batchData "latest" via? with
  | .ok ret =>
      match (LeanCli.Encoding.Json.asString ret).bind
          LeanCli.Ethereum.Multicall3.decodeAggregate3 with
      | some results =>
          let resultsArr := results.toArray
          for i in [0:misses.size] do
            let addr := misses[i]!
            match resultsArr[2*i]?, resultsArr[2*i+1]? with
            | some (decOk, decHex), some (symOk, symHex) =>
                match (if decOk then decodeDecimalsReturn decHex else none),
                      (if symOk then decodeSymbolReturn symHex else none) with
                | some d, some s =>
                    let m : TokenMeta := { decimals := d, symbol := s }
                    setMeta state chainId addr m (LeanCli.Daemon.StateVault.tierOfVia via?)
                    out := out.push (addr, some m)
                | _, _ =>
                    -- Reverted or non-ERC-20 shaped: known non-token.
                    markNoCode state chainId addr
                    out := out.push (addr, none)
            | _, _ =>
                -- Truncated result set; skip without caching.
                out := out.push (addr, none)
          pure out
      | none =>
          pure (out ++ misses.map (fun a => (a, none)))
  | .error _ =>
      pure (out ++ misses.map (fun a => (a, none)))

/-- Cache-or-fetch. Always returns the cached value when present; misses
    are filled via `fetchAndCache`. Idempotent. -/
def lookupOrFetch
    (state : LeanCli.Daemon.State.Shared)
    (policy : LeanCli.Network.Policy.Policy)
    (endpoint : LeanCli.RPC.Outbound.Endpoint)
    (chainId : Nat) (address : String) (direct : Bool := false) : IO (Option TokenMeta) := do
  -- On a `direct` (display-only) read, skip the shared cache: a value fetched
  -- earlier over the verified backend may be wrong (see `fetchAndCache`), so
  -- always resolve fresh over direct RPC. The correct value is still cached
  -- for later callers (decimals/symbol are immutable, so source-independent).
  if direct then
    fetchAndCache state policy endpoint chainId address (direct := true)
  else
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
