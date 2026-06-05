# CHANGES — Stream D (network policy simplify + re-home)

## Re-home
- `git mv LeanCli/Privacy/NetworkPolicy.lean → LeanCli/Network/Policy.lean`; namespace
  `LeanCli.Privacy.NetworkPolicy → LeanCli.Network.Policy`. Joins the existing `Network/{Endpoint,Provider}.lean`.
- Updated all 20 external importers (`import` + `open` + qualified refs) + the `LeanCli.lean` re-export.
  `git grep 'Privacy.NetworkPolicy' -- '*.lean'` is empty.

## Trim
- Removed the 4 dead `Purpose` cases (zero classifier emitters): `analytics`, `metadataLookup`,
  `fiatOnramp`, `crashReport` — from the enum, `thirdPartyPurpose`, `asString`, `parsePurpose`, `purposeNames`.
- **Kept** `indexerLookup` (LIVE — `ChainRpc.lean:570`), `peerDiscovery`, `priceQuote` (structural).
- **No policy modes removed** — all 8 remain selectable via `parsePolicy` (`cli`/`strict`/`loopback-strict`/
  `tor`/`dev`/`permissive`/`indexer`/`deny`). Deny-by-default backbone intact.

## Re-prove (Cat 6/7)
- `Invariants/Network.lean` (30 theorems) + `Invariants/Bridge.lean` (Cat 5 bridge classification) re-proven —
  only the `open` line changed; no proof-body or statement edits. `deniedThirdPartyPurposesStrict` is
  universally quantified over `req.purpose`, so trimming the enum just yields fewer `cases` subgoals;
  security meaning preserved (strict=local-only, tor=tor-only, no-credentials, deny-by-default).
- Builds: `lake build LeanCli.Invariants.Network` (106) + `…Bridge` (8) green; full `lake build` 256, zero `sorryAx`.

## Deliberately NOT done (recon corrections to the brief)
- Invariants **5.9/5.10/5.11 NOT re-homed** — they were already correctly in `Invariants/Network.lean`
  (the brief's "mis-filed" premise was wrong). Only their `open` line updated.
- Invariant **5.7 not completed** (deferred to the host stream B).
- Provider/privacy flag surface + `network show` provider/privacy printing untouched (Stream B).
- TUI network-screen merge (`NetworkMonitor`→`NetworkScreen`) deferred.

## For Stream-F (docs pass)
`CLAUDE.md`, `docs/ARCHITECTURE.md`, `docs/DAEMON.md`, `skills/*.md`, and the `sidecars/kohaku/llm-legacy/*.mjs`
(llm-legacy is deleted in Stream B) still reference the old `LeanCli.Privacy.NetworkPolicy` path in prose.
