# leanCLI docs index

Governance docs live at the repo root: [`CLAUDE.md`](../CLAUDE.md), [`INVARIANTS.md`](../INVARIANTS.md),
[`SECURITY.md`](../SECURITY.md), [`README.md`](../README.md).

## Architecture & surfaces
- [ARCHITECTURE.md](ARCHITECTURE.md) — layer model (Primitives / Domain / Surfaces / Agent), sidecars, pre-sign pipeline.
- [CLI.md](CLI.md) — thin JSON-RPC forwarder surface.
- [DAEMON.md](DAEMON.md) — wallet daemon dispatch + UDS.

## Privacy & security
- [PRIVACY_SECURITY.md](PRIVACY_SECURITY.md) — privacy trust model.
- [PRIVACY_SKILLS_CURATION.md](PRIVACY_SKILLS_CURATION.md), [PROTOCOL_SKILLS_CURATION.md](PROTOCOL_SKILLS_CURATION.md) — skills curation.

## Phase plans (agent build-out history)
- [PHASE0_PLAN.md](PHASE0_PLAN.md), [PHASE1A_PLAN.md](PHASE1A_PLAN.md), [PHASE1B_PLAN.md](PHASE1B_PLAN.md),
  [PHASE1C_PLAN.md](PHASE1C_PLAN.md), [PHASE1D_THREAT_MODEL.md](PHASE1D_THREAT_MODEL.md).

## Active refactor
- [REFACTOR_PLAN.md](REFACTOR_PLAN.md) — audit & maintainability refactor (orchestration source of truth).
- [CRYPTO_POLICY.md](CRYPTO_POLICY.md) — one-library-per-primitive crypto sourcing policy + pins.
- `CHANGES-*.md` — per-stream change logs, merged by Stream-F.
