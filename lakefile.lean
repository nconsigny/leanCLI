import Lake
open Lake DSL

package "leanKohaku" where
  version := v!"0.1.0"
  -- Mathlib is intentionally omitted for now so `lake build` stays fast
  -- while we iterate on architecture. It will be added when we start
  -- formalizing algebraic proofs (e.g. ZMod / elliptic-curve group laws
  -- for secp256k1).
  leanOptions := #[
    ⟨`pp.unicode.fun, true⟩,
    ⟨`autoImplicit, false⟩
  ]
  -- libcurl is consumed transitively by liblean_http (see below) and
  -- linked into every executable that pulls it in. We use weakLinkArgs
  -- rather than moreLinkArgs because changing the linker line for a
  -- system library should not invalidate Lean compilation caches.
  --
  -- We pass the absolute path to /usr/lib/libcurl.so to the linker
  -- rather than `-L/usr/lib -lcurl`: the Lean toolchain links against
  -- its own bundled glibc via `--sysroot`, so a bare `-L/usr/lib`
  -- accidentally drags in the host's current glibc (which on Arch is
  -- newer than the bundled one and removes symbols like
  -- `__libc_csu_init` that Scrt1.o still references). The absolute-
  -- path form only loads libcurl itself; libcurl's transitive deps
  -- (libnghttp2, libssl, …) come from the host's runtime linker
  -- search at execution time via DT_NEEDED entries on libcurl.so.4.
  weakLinkArgs := #[
    "/usr/lib/libcurl.so",
    -- libsqlite3 is the runtime dep for liblean_sqlite (Phase 1a
    -- persistent agent sessions). Same absolute-path form as libcurl
    -- to avoid the bundled-glibc / host-glibc mismatch that bare
    -- `-L/usr/lib -lsqlite3` would trigger.
    "/usr/lib/libsqlite3.so",
    -- libsqlite3 references libpthread/libdl/libm/libc symbols via
    -- DT_NEEDED, but the Lean toolchain's bundled lld defaults to
    -- --no-allow-shlib-undefined. libcurl avoids the problem because
    -- its transitive deps are all third-party libs; libsqlite3 needs
    -- libpthread/libdl (merged into glibc 2.34+) which the bundled
    -- sysroot does not advertise. Standard fix for "trust DT_NEEDED
    -- at runtime" is to allow undefined symbols from shared libs.
    "-Wl,--allow-shlib-undefined"
  ]

lean_lib LeanKohaku where

@[default_target]
lean_lib LeanKohakuClient where
  roots := #[`LeanKohaku.Lib.Client]

@[default_target]
lean_lib LeanKohakuCore where
  roots := #[`LeanKohaku.Lib.Core]

@[default_target]
lean_lib LeanKohakuSpec where
  roots := #[`LeanKohaku.Lib.Spec]

extern_lib liblean_uds pkg := do
  let srcJob ← inputTextFile <| pkg.dir / "c" / "lean_uds" / "lean_uds.c"
  let lean ← getLeanInstall
  let oJob ← buildO (pkg.buildDir / "native" / "lean_uds.o") srcJob
    #["-I", lean.includeDir.toString, "-fPIC"] #[]
  buildStaticLib (pkg.buildDir / "native" / "liblean_uds.a") #[oJob]

-- Loopback-only HTTP POST shim consumed by LeanKohaku/Agent/Http.lean.
-- Compiled against the system libcurl headers; the actual `-lcurl`
-- link arg is set in the package-level `weakLinkArgs` above.
extern_lib liblean_http pkg := do
  let srcJob ← inputTextFile <| pkg.dir / "c" / "lean_http" / "lean_http.c"
  let lean ← getLeanInstall
  let oJob ← buildO (pkg.buildDir / "native" / "lean_http.o") srcJob
    #["-I", lean.includeDir.toString,
      "-I", (pkg.dir / "c" / "lean_http").toString,
      "-fPIC"] #[]
  buildStaticLib (pkg.buildDir / "native" / "liblean_http.a") #[oJob]

-- SQLite FFI shim consumed by LeanKohaku/Agent/Session.lean (Phase 1a
-- persistent agent sessions). Linked against the system libsqlite3 —
-- Arch (`sqlite`) and Debian 12+ (`libsqlite3-0`) ship FTS5 enabled.
-- See `c/lean_sqlite/README.md` for the vendoring tradeoff.
extern_lib liblean_sqlite pkg := do
  let srcJob ← inputTextFile <| pkg.dir / "c" / "lean_sqlite" / "lean_sqlite.c"
  let lean ← getLeanInstall
  let oJob ← buildO (pkg.buildDir / "native" / "lean_sqlite.o") srcJob
    #["-I", lean.includeDir.toString,
      "-I", (pkg.dir / "c" / "lean_sqlite").toString,
      "-fPIC"] #[]
  buildStaticLib (pkg.buildDir / "native" / "liblean_sqlite.a") #[oJob]

@[default_target]
lean_exe leankohaku where
  root := `LeanKohaku.App.Main
  supportInterpreter := true

@[default_target]
lean_exe «leankohaku-daemon» where
  root := `LeanKohaku.App.DaemonMain
  supportInterpreter := true

/--
Lean-native LLM agent (Phase 0). One-shot replacement for the legacy
`bridge/llm/bridge.mjs` Node sidecar. Accepts `--rpc '<json>'` on argv,
runs the Lean agent loop, emits one JSON-RPC envelope line on stdout.

`LlmAgent.Bridge` switches to this binary by default; the legacy
sidecar is reachable via `LEAN_KOHAKU_LLM_BRIDGE_LEGACY=1`.
-/
lean_exe kohaku_agent where
  root := `LeanKohaku.App.AgentMain
  supportInterpreter := true

/--
SQLite session-store smoke test (Phase 1a). Exercises schema
bootstrap, append + load, tool-call round-trip, FTS5 search, and a
second-handle concurrent read. Build with
`lake build agent_session_test`, run with
`.lake/build/bin/agent_session_test`. Exits non-zero on any
regression — `tests/agent_phase1a_smoke.sh` runs it as a prereq.
-/
lean_exe agent_session_test where
  root := `LeanKohaku.Agent.SessionTest
  supportInterpreter := true

/--
Long-running persistent agent daemon (Phase 1a). Listens on
`$XDG_RUNTIME_DIR/leankohaku/agent.sock` and serves session-scoped
chat turns backed by `LeanKohaku/Agent/Session.lean`. Mode resolution
in `LlmAgent.Bridge.lean` auto-detects this socket and falls back to
the Phase 0 one-shot path when it is missing.
-/
lean_exe kohaku_agentd where
  root := `LeanKohaku.App.AgentDaemonMain
  supportInterpreter := true

lean_exe «leankohaku-eip712-check» where
  root := `LeanKohaku.App.Eip712Check
  supportInterpreter := true

lean_exe «leankohaku-ens-check» where
  root := `LeanKohaku.App.EnsCheck
  supportInterpreter := true

/--
Generate the bundled Railgun cold-start snapshot for `bridge/`.

Runs the railgun bridge sidecar with a deterministic dummy seed against
Sepolia, lets `@kohaku-eth/railgun`'s indexer fully sync the on-chain
UTXO tree + POI metadata into a temp storage file, then moves that
file to `bridge/railgun-sepolia-snapshot.json`. The bridge cold-start
hook in `bridge/bridge.mjs` copies this snapshot into a user's storage
path on first call so they skip the multi-minute initial sync.

The snapshot contains chain-wide indexer state only — no per-user
keys. alpha-21 derives signers from `host.keystore` on every plugin
construction, so the snapshot is keystore-agnostic.

Run as a one-shot dev tool when refreshing the snapshot for a release:
  lake env .lake/build/bin/leankohaku-railgun-snapshot
-/
lean_exe «leankohaku-railgun-snapshot» where
  root := `LeanKohaku.App.RailgunSnapshotMain
  supportInterpreter := true

/--
SPHINCS- shim smoke test. Build with `lake build leankohaku-sphincs-test`,
run with `lake env .lake/build/bin/leankohaku-sphincs-test`. Exits 0 on
success or when the shim binaries are absent; non-zero on a real
roundtrip failure. See `LeanKohaku/Sphincs/Test.lean`.
-/
lean_exe «leankohaku-sphincs-test» where
  root := `LeanKohaku.Sphincs.Test
  supportInterpreter := true

/--
Build the SPHINCS- shim binaries (`sphincs-slhdsa-128-24` and `sphincs-c7`)
into `.lake/build/bin/`. Skips with a clear non-fatal message if `make`
or `cc` is unavailable, so non-Linux dev hosts are not blocked. Linux CI
should invoke `lake script run sphincs-shims` and check its stderr for
the `[sphincs-shims] built` confirmation. We deliberately do not hook
this into `lean_exe`/`extern_lib` because the C signer does not
participate in incremental Lean compilation.
-/
-- Build the native crypto helpers (`leankohaku-hacl-*`,
-- `leankohaku-secp256k1-*`) that the wallet daemon shells out to for
-- every PBKDF2, HMAC, Keccak, ChaCha20-Poly1305, and ECDSA op. They
-- are NOT produced by `lake build` because the bootstrap clones
-- hacl-packages + bitcoin-core/secp256k1 and runs CMake/Ninja + cargo
-- — too heavy for incremental Lean compilation. This script wraps the
-- two bash setup scripts so users have one discoverable recovery
-- command:
--
--   lake script run setup-helpers
--
-- The wallet daemon's boot-time precheck refuses to start when these
-- helpers are missing, so a successful run of this script is also the
-- unblock for `wallet unlock` / `eoa.send` / TPM wrap failures.
script «setup-helpers» (args) do
  let _ := args
  let pkgDir ← IO.currentDir
  let runScript (name : String) : IO Bool := do
    let path := pkgDir / "script" / name
    if !(← path.pathExists) then
      IO.eprintln s!"[setup-helpers] script not found: {path}"
      return false
    try
      let child ← IO.Process.spawn {
        cmd := "bash",
        args := #[path.toString],
        stdin := .null,
        stdout := .inherit,
        stderr := .inherit
      }
      let code ← child.wait
      pure (code == 0)
    catch e =>
      IO.eprintln s!"[setup-helpers] {name} failed: {e}"
      pure false
  let okHacl ← runScript "setup_hacl.sh"
  let okSecp ← runScript "setup_secp256k1.sh"
  if okHacl && okSecp then
    IO.println "[setup-helpers] ok — wallet daemon helpers built"
    return 0
  else
    IO.eprintln "[setup-helpers] FAILED — see errors above"
    return 1

script «sphincs-shims» (args) do
  let _ := args
  let pkgDir ← IO.currentDir
  let sidecarDir := pkgDir / "sidecars" / "sphincs"
  if !(← sidecarDir.pathExists) then
    IO.eprintln s!"[sphincs-shims] no sidecar dir at {sidecarDir}, skipping"
    return 0
  let outDir := pkgDir / ".lake" / "build" / "bin"
  IO.FS.createDirAll outDir
  let runOk : IO Bool := do
    try
      let child ← IO.Process.spawn {
        cmd := "make",
        args := #["-C", sidecarDir.toString, s!"OUT_DIR={outDir}", "all"],
        stdin := .null,
        stdout := .inherit,
        stderr := .inherit
      }
      let code ← child.wait
      pure (code == 0)
    catch e =>
      IO.eprintln s!"[sphincs-shims] make failed: {e}"
      pure false
  if (← runOk) then
    IO.println s!"[sphincs-shims] built into {outDir}"
  else
    IO.eprintln
      "[sphincs-shims] build failed (cc/make missing or compile error); continuing"
  -- Skip-on-failure: dev hosts without `cc` are not blocked; CI grep the
  -- log line above and fails loudly if it is missing.
  return 0
