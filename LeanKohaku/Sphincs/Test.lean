import LeanKohaku.Sphincs.Bridge

/-!
# SPHINCS- shim smoke-test executable

Runs `Sphincs.smokeRoundtrip` against each parameter set's binary. Both
the NIST variant (`slhDsaSha2_128_24`) and the WOTS+C / FORS+C C9 variant
must succeed end-to-end (keygen → sign → verify-after-sign).

Used by humans / CI as:

    lake script run sphincs-shims                      # build binaries
    lake env .lake/build/bin/leankohaku-sphincs-test   # run the smoke

The executable exits 0 on the expected outcomes and non-zero otherwise,
so it can be added to a CI pipeline. It prints one human-readable line
per parameter set; nothing structured (no test framework dependency).

If the binaries are absent (e.g. on a non-Linux dev host where the
shim Makefile failed), the executable prints `[skipped]` lines and
still exits 0 — the brief's "skip-fail gracefully" requirement.
-/

open LeanKohaku.Sphincs

/-- 48-byte deterministic seed for the SLH-DSA-SHA2-128-24 variant. -/
def slhdsaSeedHex : String :=
  "000102030405060708090a0b0c0d0e0f" ++
  "101112131415161718191a1b1c1d1e1f" ++
  "202122232425262728292a2b2c2d2e2f"

/-- 32-byte digest (placeholder userOpHash). -/
def digestHex : String :=
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

/-- 16-byte optrand (deterministic for reproducibility). -/
def optrandHex : String :=
  "cafebabecafebabecafebabecafebabe"

/-- Render an `Err` for human consumption. Keep it terse: this is a
    smoke test, not a debugging surface. -/
def errToString : Err → String
  | .spawn m => s!"spawn: {m}"
  | .rpc c m => s!"rpc {c}: {m}"
  | .parse m _ => s!"parse: {m}"
  | .sizeMismatch f g e => s!"size {f}: got {g}, expected {e}"
  | .paramSetMismatch g e => s!"paramSet: got '{g}', expected '{e}'"
  | .stubBinary p => s!"stub binary: {p}"
  | .verifyAfterSignFailed => "verify-after-sign rejected the signature"

/-- Treat an `info` failure with a spawn-error as "binary missing", and
    skip the test rather than fail. Anything else is a real failure. -/
def runSmoke (label : String) (ps : ParamSet) (seedHex : String)
    (expectStub : Bool) : IO Bool := do
  match ← info ps with
  | .error (.spawn m) =>
      IO.println s!"[skipped] {label}: shim binary not runnable ({m})"
      pure true
  | .error e =>
      IO.println s!"[FAIL] {label}: info errored: {errToString e}"
      pure false
  | .ok ib =>
      if ib.stub ≠ expectStub then
        IO.println s!"[FAIL] {label}: info.stub = {ib.stub}, expected {expectStub}"
        pure false
      else if expectStub then
        -- Stub binary: smokeRoundtrip must reject with Err.stubBinary.
        match ← smokeRoundtrip ps seedHex digestHex (some optrandHex) with
        | .error (.stubBinary _) =>
            IO.println s!"[ok stub] {label}: rejected as stub (expected)"
            pure true
        | .ok _ =>
            IO.println s!"[FAIL] {label}: stub roundtrip succeeded — should error"
            pure false
        | .error e =>
            IO.println s!"[FAIL] {label}: stub roundtrip wrong error: {errToString e}"
            pure false
      else
        match ← smokeRoundtrip ps seedHex digestHex (some optrandHex) with
        | .ok true =>
            IO.println s!"[ok]      {label}: keygen→sign→verify roundtrip"
            pure true
        | .ok false =>
            IO.println s!"[FAIL]    {label}: roundtrip returned false"
            pure false
        | .error e =>
            IO.println s!"[FAIL]    {label}: {errToString e}"
            pure false

def main : IO UInt32 := do
  let okSlh ← runSmoke "SLH-DSA-SHA2-128-24"
                       ParamSet.slhDsaSha2_128_24 slhdsaSeedHex (expectStub := false)
  -- C9 takes a 32-byte seed (truncated from the same source the SLH-DSA
  -- variant uses, so both runs are reproducible from the file's literal).
  let c9Seed : String := slhdsaSeedHex.take 64
  let okC9 ← runSmoke "C9" ParamSet.c9 c9Seed (expectStub := false)
  pure (if okSlh && okC9 then 0 else 1)
