# CHANGES — Stream-0 (Phase 1: repo-layout move)

Pure plumbing, no behavior change. Stream-F merges this into the governance docs.

## Directory moves (`git mv`)

| From | To |
|---|---|
| `c/` | `native/` |
| `bridge/` | `sidecars/kohaku/` |
| `bridge/clearsign/` (→ via kohaku) | `sidecars/clearsign/` (own sidecar, sibling of kohaku) |
| `lib/sphincs-minus/` (submodule) | `vendor/sphincs-minus/` (`.gitmodules` `path` updated) |
| `script/` | `ops/scripts/` |
| `packaging/` | `ops/packaging/` |
| `tests/` | `ops/tests/` |

Empty `lib/` removed. The 10.9 MB chain-state JSON (`ppv1-{mainnet,sepolia}-state.json`,
`railgun-sepolia-snapshot.json`) **moved with `bridge/ → sidecars/kohaku/`** (still git-tracked).

## Path-reference fixes

- **`lakefile.lean`**: 5 `extern_lib` source paths `c/ → native/`; `setup-helpers` script dir
  `"script" → "ops"/"scripts"`. (`pkg.buildDir / "native"` output dir was already `native`, unchanged.)
- **`.gitignore`**: `c/ → native/`, `bridge/ → sidecars/kohaku/`, `bridge/clearsign/ → sidecars/clearsign/`.
- **Lean spawn-path literals (11 functional)**: `Privacy/Bridge`, `Clearsign/Bridge`, `Colibri/Persistent`,
  `Helios/Persistent`, `SafeNode/Persistent`, `LlmAgent/Bridge`, `Daemon/Status` (×4),
  `App/RailgunSnapshotMain`. clearsign → `sidecars/clearsign`, all else → `sidecars/kohaku`.
- **Lean `script/` refs (functional)**: daemon spawns in `Daemon/Server/SphincsRpc.lean` and
  `Daemon/Server/TpmRpc.lean`; `Cli/Runtime.lean` `leanclispawn` resolver (segment + hints);
  `Cli/Commands.lean`, `Daemon/Server/Connection.lean` precheck hint — all `script/ → ops/scripts/`.
- **Lean doc comments**: `c/lean_* → native/lean_*`; `bridge/* → sidecars/...` across ~12 modules.
- **`ops/scripts/*.sh`**: `ROOT` depth `/.. → /../..` (scripts are one level deeper); `${ROOT}/c/ →
  ${ROOT}/native/` in setup scripts; `check_m6` sibling call `script/ → ops/scripts/`.
- **`ops/tests/*.sh`**: `agent_phase*_smoke.sh` cd-to-root depth `/.. → /../..`; `safenode_smoke.sh`
  pkill pattern `bridge/ → sidecars/kohaku/`.
- **`ops/scripts/leanclispawn`**: pkill patterns, wrapper-shim table, package-discovery loop (now also
  globs the sibling `sidecars/clearsign`), data-asset paths, self-install + systemd-unit paths, curl
  URL — all updated. Function/flag names (`build_bridges`, `--no-bridges`) left as identifiers.
- **`.github/workflows/lean_action_ci.yml`**: `./script/ → ./ops/scripts/`.
- **`default.nix`**: `packaging/ → ops/packaging/`, `script/ → ops/scripts/` (prefix only).
- **`flake.nix`**: path-agnostic, no change.

## Deferred / flagged

- **Snapshot gitignore + fetch-on-first-run**: NOT done in Phase 1 — it is a behavior change
  (cold-start would depend on a network fetch) and needs a real fetch source. Tracked for a later
  hygiene pass; snapshots remain tracked under `sidecars/kohaku/` for now.
- **Governance docs** (`README.md`, `CLAUDE.md`, `SECURITY.md`) still reference old paths
  (`c/`, `bridge/`, `script/`). Deferred to Stream-F per the conflict table.
- **`default.nix:58–59` pre-existing drift**: installs `ops/packaging/systemd/leancli.socket` and
  `leancli.service`, but the dir actually contains `leancli-daemon.service` + `leancli-agentd.service`.
  Pre-existing mismatch (the real installer `leanclispawn` uses the correct names). Flag for Stream-F.
- **`.gitmodules` section name** still `[submodule "lib/sphincs-minus"]` (label only; `path` correctly
  points to `vendor/sphincs-minus`). Functional; left for cosmetic cleanup if desired.
