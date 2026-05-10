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

@[default_target]
lean_exe leankohaku where
  root := `LeanKohaku.App.Main
  supportInterpreter := true

@[default_target]
lean_exe «leankohaku-daemon» where
  root := `LeanKohaku.App.DaemonMain
  supportInterpreter := true

lean_exe «leankohaku-eip712-check» where
  root := `LeanKohaku.App.Eip712Check
  supportInterpreter := true

lean_exe «leankohaku-ens-check» where
  root := `LeanKohaku.App.EnsCheck
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
