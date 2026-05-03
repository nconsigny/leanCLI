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
