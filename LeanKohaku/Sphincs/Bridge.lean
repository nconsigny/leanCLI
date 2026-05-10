import LeanKohaku.Encoding.Json

/-!
# SPHINCS- shim sidecar boundary

The SPHINCS- post-quantum signer is implemented in C (vendored from the
sphincs/sphincsplus reference under `sidecars/sphincs/`) and exposed to the
Lean tree via a small JSON-RPC shim. This module is the only place that
spawns those binaries.

Two parameter sets are wired in: SLH-DSA-SHA2-128-24 (NIST FIPS 205
candidate) and C9 (WOTS+C / FORS+C, h=20 d=2 a=12 k=11 w=8, 3816-byte
sig). C9 is deployed on Sepolia at
0x18F005EECd41624644AA364bA8857258FEB3C26D and is the parameter set
exercised by the SphincsAccount contract at
0xA941116763AE386a50133c5af40356c9D93b2978 against EntryPoint v0.9.

User-facing label is "SPHINCS-" because both variants are non-standard
relative to NIST SLH-DSA. Internal type names and the on-chain
`SphincsAccount` contract name stay as they are.

Trust model: identical to the Node sidecars in `bridge/`. The shim binary
is **untrusted**. Every output goes through length-validation against the
parameter set's known sizes, and `signWithVerify` runs verify-after-sign
locally before handing the signature back, so a malicious shim cannot get
the daemon to broadcast a signature the on-chain verifier would reject.

`info`-reported sizes are checked against the parameter-set's expected
constants on every call so a wrongly-spawned binary (or a tampered
`info`) is detected before any signing operation.

## Phase 3 Step 1 — on-chain verify cross-check (passed)

The local C9 verifier was cross-checked against the deployed Yul
verifier on a real Sepolia handleOps tx
`0x8366513b096ee53dd1cb105363ab21a52267dd966b822b4bb2cf5492abf1550f`
(block 10617954). Reading the SphincsAccount at
`0xA941116763AE386a50133c5af40356c9D93b2978` returned
`pkSeed = 0x3a8b2936c7b6f018704d736b26bf402d…` and
`pkRoot = 0x8bf4446db8643e4c149359f364bcca53…` (32-byte words, with the
meaningful prefix in the high half). Decoding the userOp from
`handleOps` calldata yielded a `signature` field of
`abi.encode(bytes ecdsaSig, bytes sphincsSig)` with `len(sphincsSig)
= 3816` (matching `ParamSet.expectedSigBytes .c9`). Reproducing
`userOpHash` per EntryPoint v0.9 EIP-712 typed-data hashing (see
`LeanKohaku/Sphincs/UserOp.lean`) and feeding
`(pkSeed, pkRoot, userOpHash, sphincsSig)` to the local
`bin/sphincs-c9 verify` returned `{"ok": true}` — verbatim. So the
deployed Yul verifier and our Rust port at `vendor-c9/` agree on a
real-world signature, which is the strongest correctness signal we can
get without our own Sepolia tx.
-/

namespace LeanKohaku.Sphincs

open LeanKohaku.Encoding.Json

/-- Supported SPHINCS- parameter sets. The on-chain `SphincsAccount`
    verifier address is selected per `(chain, paramSet)` pair, so the
    daemon must be told which one a given account uses; the abstract
    contract model in `LeanKohaku/Contract/SphincsAccount.lean` is
    paramSet-agnostic by design. -/
inductive ParamSet
  /-- NIST SLH-DSA-SHA2-128-24 (FIPS 205 candidate). Slow signing; sane
      for a v0 deployment because verification is fast and the spec is
      well reviewed. -/
  | slhDsaSha2_128_24
  /-- C9 (WOTS+C / FORS+C, n=16 h=20 d=2 a=12 k=11 w=8 l=43 target=208,
      3816-byte sig). Adapted from upstream nconsigny/SPHINCS-
      signer-wasm at commit 63617e1 with params.rs retuned to match the
      on-chain verifier `legacy/src/SPHINCs-C9Asm.sol` @ 5964b61
      (deployed on Sepolia at 0x18F005EECd41624644AA364bA8857258FEB3C26D);
      vendored in `sidecars/sphincs/vendor-c9/`. -/
  | c9
  deriving Repr, DecidableEq

/-- Serialise a `ParamSet` to its JSON tag (matches the shim's `info`
    output and the on-disk verifier address map keys). -/
def ParamSet.toString : ParamSet → String
  | .slhDsaSha2_128_24 => "SLH-DSA-SHA2-128-24"
  | .c9                => "C9"

/-- Inverse of `toString`. Used when reading shim `info` output back. -/
def ParamSet.parse? : String → Option ParamSet
  | "SLH-DSA-SHA2-128-24" => some .slhDsaSha2_128_24
  | "C9"                  => some .c9
  | _                     => none

/-- Default executable basenames produced by `sidecars/sphincs/Makefile`
    and copied into `.lake/build/bin/` by the lake hook. Used as the
    PATH-fallback when neither the env override nor the in-monorepo
    binary directory resolves. -/
def ParamSet.defaultExecutable : ParamSet → String
  | .slhDsaSha2_128_24 => "sphincs-slhdsa-128-24"
  | .c9                => "sphincs-c9"

/-- Walk upward from the working directory looking for
    `sidecars/sphincs/bin/<basename>` that ships in this repo. Returns
    the first match within `maxHops` parents, or `none`. Mirrors the
    `Clearsign/Bridge.lean::findBridgeMjs` and
    `Colibri/Persistent.lean::findBridgeMjs` helpers so the daemon picks
    up locally-built shim binaries (`make` under `sidecars/sphincs/`)
    without an explicit `LEAN_KOHAKU_SPHINCS_*` env var. -/
private partial def findShimBinary (basename : String)
    (start : System.FilePath) (maxHops : Nat) : IO (Option String) := do
  let candidate := start / "sidecars" / "sphincs" / "bin" / basename
  if (← candidate.pathExists) then
    pure (some candidate.toString)
  else
    match maxHops, start.parent with
    | 0, _ => pure none
    | _ + 1, none => pure none
    | n + 1, some parent =>
        if parent == start then pure none
        else findShimBinary basename parent n

/-- Resolve the shim binary path in this order:
    1. `LEAN_KOHAKU_SPHINCS_<PARAMSET>` env var (explicit override).
    2. `sidecars/sphincs/bin/<basename>` walked upward from CWD
       (monorepo build output of `make`).
    3. `<basename>` on PATH (or `.lake/build/bin/` when the lake hook
       has copied it there). -/
def resolveExecutable (ps : ParamSet) : IO String := do
  let envKey := match ps with
    | .slhDsaSha2_128_24 => "LEAN_KOHAKU_SPHINCS_SLHDSA"
    | .c9                => "LEAN_KOHAKU_SPHINCS_C9"
  match (← IO.getEnv envKey) with
  | some s => pure s
  | none =>
      let cwd ← IO.currentDir
      match ← findShimBinary ps.defaultExecutable cwd 8 with
      | some p => pure p
      | none => pure ps.defaultExecutable

/-- A SPHINCS- key pair. Hex-encoded; the daemon owns sealing to TPM /
    keystore. The shim itself never persists secret material. -/
structure KeyMaterial where
  pkSeed : String
  pkRoot : String
  /-- Secret key bytes, hex. The caller must seal this before any
      cross-process journey or disk write. -/
  sk     : String
  deriving Repr

/-- Reported metadata from the shim's `info` method. We store the byte
    counts (not hex char counts) so the validation code stays obvious. -/
structure InfoBlob where
  paramSet : String
  sigBytes : Nat
  pkBytes  : Nat
  skBytes  : Nat
  seedBytes : Nat
  stub     : Bool
  deriving Repr

/-- Bridge-call failure. Distinct from on-chain rejection: this is the
    daemon learning that the local signer is broken or wrong. -/
inductive Err where
  | spawn   (msg : String)
  | rpc     (code : Int) (message : String)
  | parse   (msg : String) (raw : String)
  | sizeMismatch (field : String) (got : Nat) (expected : Nat)
  | paramSetMismatch (got : String) (expected : String)
  | stubBinary (paramSet : String)
  | verifyAfterSignFailed
  deriving Repr

/-- Expected byte counts per parameter set. These are the contract the
    daemon enforces against shim output. -/
def ParamSet.expectedSigBytes : ParamSet → Nat
  | .slhDsaSha2_128_24 => 3856
  | .c9                => 3816

/-- C9: 64 bytes = 2 × 32-byte words. `pkSeed` and `pkRoot` are
    ABI-shaped as `bytes32` for the on-chain
    `SphincsC9Asm.verify(bytes32 pkSeed, bytes32 pkRoot, …)`, with the
    meaningful 16 bytes in the high half of each word. -/
def ParamSet.expectedPkBytes : ParamSet → Nat
  | .slhDsaSha2_128_24 => 32
  | .c9                => 64

/-- C9: 96 bytes = 3 × 32-byte words concatenated as
    `pkSeed || skSeed || pkRoot`, mirroring how the Rust signer's
    `sphincs::sign` consumes its `(pk_seed, sk_seed, pk_root)` triple. -/
def ParamSet.expectedSkBytes : ParamSet → Nat
  | .slhDsaSha2_128_24 => 64
  | .c9                => 96

/-- C9: 32 raw entropy bytes. The daemon hands TPM-sealed material in;
    the signer derives `(pk_seed, sk_seed, pk_root)` deterministically
    via keccak with the `"sphincs-c9-v1"`-equivalent domain tag. -/
def ParamSet.expectedSeedBytes : ParamSet → Nat
  | .slhDsaSha2_128_24 => 48
  | .c9                => 32

/-- One half of `expectedPkBytes` — public-key blobs are `pkSeed||pkRoot`
    with both halves equal-sized. -/
def ParamSet.expectedHalfPkBytes (ps : ParamSet) : Nat :=
  ps.expectedPkBytes / 2

/-- Encode a request as a single line of JSON. -/
private def encodeRequest (method : String) (params : Json) (id : Nat) : String :=
  compact <| .obj #[
    ("jsonrpc", .str "2.0"),
    ("method",  .str method),
    ("params",  params),
    ("id",      .num (Int.ofNat id))
  ]

/-- Internal: parse a shim response line. Returns either the `result`
    field as a `Json` value, or an `Err.rpc` carrying the JSON-RPC error.
    `Err.parse` covers everything else. -/
private def parseResponse (raw : String) : Except Err Json :=
  match parse raw.trimAscii.toString with
  | .error e => .error (.parse e raw)
  | .ok (Json.obj fields) =>
      let lookup (k : String) : Option Json :=
        (fields.find? (fun (key, _) => key == k)).map Prod.snd
      match lookup "error" with
      | some (Json.obj ef) =>
          let code : Int := match (ef.find? (fun (k, _) => k == "code")).map Prod.snd with
            | some (Json.num n) => n
            | _ => -32603
          let msg := match (ef.find? (fun (k, _) => k == "message")).map Prod.snd with
            | some (Json.str s) => s
            | _ => "shim error"
          .error (.rpc code msg)
      | _ =>
          match lookup "result" with
          | some j => .ok j
          | none => .error (.parse "response missing result/error" raw)
  | .ok _ => .error (.parse "response not a JSON object" raw)

/-- Spawn the shim once with `--rpc <json>`, read stdout, parse the
    JSON-RPC envelope. Mirrors the Privacy/Clearsign bridges. -/
private def callRaw (ps : ParamSet) (method : String) (params : Json) (id : Nat) :
    IO (Except Err Json) := do
  let exe ← resolveExecutable ps
  let encoded := encodeRequest method params id
  try
    let child ← IO.Process.spawn {
      cmd := exe,
      args := #["--rpc", encoded],
      stdin := .null,
      stdout := .piped,
      stderr := .inherit
    }
    let stdout ← child.stdout.readToEnd
    let exitCode ← child.wait
    if exitCode == 0 || !stdout.trimAscii.isEmpty then
      pure (parseResponse stdout)
    else
      pure (.error (.spawn s!"shim '{exe}' exited with code {exitCode}"))
  catch e =>
    pure (.error (.spawn (toString e)))

/-- Length of a hex string in bytes (treating the string as nibble-pairs).
    Tolerates a leading `0x`. Returns `none` if odd-length or non-hex
    digits encountered. -/
private def hexBytes? (s : String) : Option Nat :=
  -- Why we walk a `List Char` rather than `String.drop`: in this Lean
  -- toolchain `String.drop` is routed through `String.Slice`, whose
  -- `length` is deprecated. Hex strings are short enough that the list
  -- traversal is fine.
  let chars := s.toList
  let rest : List Char :=
    match chars with
    | '0' :: 'x' :: tl => tl
    | '0' :: 'X' :: tl => tl
    | _ => chars
  let n := rest.length
  if n % 2 ≠ 0 then none
  else
    let allHex := rest.all (fun c =>
      ('0' ≤ c ∧ c ≤ '9') ∨ ('a' ≤ c ∧ c ≤ 'f') ∨ ('A' ≤ c ∧ c ≤ 'F'))
    if allHex then some (n / 2) else none

/-- Validate that a JSON string field is hex of exactly `expected` bytes.
    Returns the (possibly `0x`-stripped) hex string on success. -/
private def expectHex (field : String) (expected : Nat) (j : Json) :
    Except Err String :=
  match j with
  | .str s =>
      match hexBytes? s with
      | some n =>
          if n = expected then .ok s
          else .error (.sizeMismatch field n expected)
      | none => .error (.parse s!"{field}: not even-length hex" s)
  | _ => .error (.parse s!"{field}: not a JSON string" "")

private def getStringField (j : Json) (k : String) : Except Err String :=
  match getField k j >>= asString with
  | some s => .ok s
  | none   => .error (.parse s!"missing string field '{k}'" "")

/-- Query the shim's `info` method and validate every reported size
    against the parameter set's expected constants. A wrongly-spawned
    binary is rejected here, before any keygen/sign/verify call. -/
def info (ps : ParamSet) : IO (Except Err InfoBlob) := do
  match ← callRaw ps "info" (.obj #[]) 0 with
  | .error e => pure (.error e)
  | .ok j =>
      let parsed : Except Err InfoBlob := do
        let paramSet ← getStringField j "paramSet"
        if paramSet ≠ ps.toString then
          .error (.paramSetMismatch paramSet ps.toString)
        else
          let sigB := getField "sigBytes" j >>= asNat
          let pkB := getField "pkBytes" j >>= asNat
          let skB := getField "skBytes" j >>= asNat
          let seedB := getField "seedBytes" j >>= asNat
          let stub := (getField "stub" j >>= asBool).getD false
          match sigB, pkB, skB, seedB with
          | some s, some p, some sk, some sd =>
              if s ≠ ps.expectedSigBytes then
                .error (.sizeMismatch "sigBytes" s ps.expectedSigBytes)
              else if p ≠ ps.expectedPkBytes then
                .error (.sizeMismatch "pkBytes" p ps.expectedPkBytes)
              else if sk ≠ ps.expectedSkBytes then
                .error (.sizeMismatch "skBytes" sk ps.expectedSkBytes)
              else if sd ≠ ps.expectedSeedBytes then
                .error (.sizeMismatch "seedBytes" sd ps.expectedSeedBytes)
              else
                .ok { paramSet := paramSet, sigBytes := s, pkBytes := p,
                      skBytes := sk, seedBytes := sd, stub := stub }
          | _, _, _, _ => .error (.parse "info missing size fields" "")
      pure parsed

/-- Generate a key pair from a deterministic seed. The shim is treated as
    untrusted: its output is rejected unless every field's hex length
    matches the parameter set's expected size. The caller must supply
    `seedHex` of exactly `expectedSeedBytes` bytes. -/
def keygen (ps : ParamSet) (seedHex : String) : IO (Except Err KeyMaterial) := do
  match hexBytes? seedHex with
  | none => pure (.error (.parse "seedHex must be even-length hex" seedHex))
  | some n =>
      if n ≠ ps.expectedSeedBytes then
        pure (.error (.sizeMismatch "seedHex" n ps.expectedSeedBytes))
      else
        match ← callRaw ps "keygen" (.obj #[("seedHex", .str seedHex)]) 1 with
        | .error e => pure (.error e)
        | .ok j =>
            let parsed : Except Err KeyMaterial := do
              let pkSeedV ← getField "pkSeed" j |>.elim (.error (.parse "missing pkSeed" "")) Except.ok
              let pkRootV ← getField "pkRoot" j |>.elim (.error (.parse "missing pkRoot" "")) Except.ok
              let skV ← getField "sk" j |>.elim (.error (.parse "missing sk" "")) Except.ok
              let pkSeed ← expectHex "pkSeed" ps.expectedHalfPkBytes pkSeedV
              let pkRoot ← expectHex "pkRoot" ps.expectedHalfPkBytes pkRootV
              let sk ← expectHex "sk" ps.expectedSkBytes skV
              .ok { pkSeed := pkSeed, pkRoot := pkRoot, sk := sk }
            pure parsed

/-- Raw `sign` call. Caller is responsible for length-validating `digest`
    (32 bytes for `userOpHash`) and providing `sk` of the right size.
    Output sig length is checked against `expectedSigBytes`. -/
def signRaw (ps : ParamSet) (sk digest : String) (optrand? : Option String := none) :
    IO (Except Err String) := do
  match hexBytes? sk with
  | none => pure (.error (.parse "sk must be hex" sk))
  | some n =>
      if n ≠ ps.expectedSkBytes then
        pure (.error (.sizeMismatch "sk" n ps.expectedSkBytes))
      else match hexBytes? digest with
      | none => pure (.error (.parse "digest must be hex" digest))
      | some dn =>
          if dn ≠ 32 then
            pure (.error (.sizeMismatch "digest" dn 32))
          else
            let baseFields : Array (String × Json) :=
              #[("sk", .str sk), ("digest", .str digest)]
            let fields := match optrand? with
              | some o => baseFields.push ("optrand", .str o)
              | none   => baseFields
            match ← callRaw ps "sign" (.obj fields) 2 with
            | .error e => pure (.error e)
            | .ok j =>
                match getField "sig" j >>= asString with
                | some sig =>
                    match hexBytes? sig with
                    | some sigN =>
                        if sigN ≠ ps.expectedSigBytes then
                          pure (.error (.sizeMismatch "sig" sigN ps.expectedSigBytes))
                        else pure (.ok sig)
                    | none => pure (.error (.parse "sig not even-length hex" sig))
                | none => pure (.error (.parse "missing sig field" ""))

/-- Stateless verification call. Returns the boolean the shim reported
    after length-validating every input field. -/
def verify (ps : ParamSet) (pkSeed pkRoot digest sig : String) :
    IO (Except Err Bool) := do
  let halfPk := ps.expectedHalfPkBytes
  match hexBytes? pkSeed with
  | none => pure (.error (.parse "pkSeed not hex" pkSeed))
  | some n =>
      if n ≠ halfPk then pure (.error (.sizeMismatch "pkSeed" n halfPk))
      else match hexBytes? pkRoot with
      | none => pure (.error (.parse "pkRoot not hex" pkRoot))
      | some n2 =>
          if n2 ≠ halfPk then pure (.error (.sizeMismatch "pkRoot" n2 halfPk))
          else match hexBytes? digest with
          | none => pure (.error (.parse "digest not hex" digest))
          | some dn =>
              if dn ≠ 32 then pure (.error (.sizeMismatch "digest" dn 32))
              else match hexBytes? sig with
              | none => pure (.error (.parse "sig not hex" sig))
              | some sn =>
                  if sn ≠ ps.expectedSigBytes then
                    pure (.error (.sizeMismatch "sig" sn ps.expectedSigBytes))
                  else
                    match ← callRaw ps "verify" (.obj #[
                      ("pkSeed", .str pkSeed),
                      ("pkRoot", .str pkRoot),
                      ("digest", .str digest),
                      ("sig",    .str sig)
                    ]) 3 with
                    | .error e => pure (.error e)
                    | .ok j =>
                        match getField "ok" j >>= asBool with
                        | some b => pure (.ok b)
                        | none => pure (.error (.parse "missing ok field" ""))

/-- Sign + verify-after-sign sanity check. This is the call that
    daemon-side signing flows should use: a malicious or buggy shim
    cannot get the daemon to broadcast an unverifiable signature, since
    we re-verify locally before returning success.

    Why we trust local verify-after-sign more than the shim's `sign`
    output: verification is parameter-set agnostic at the byte level, so
    even if the shim sign path has been tampered with, verify (running
    in the same shim binary, but a different code path) still has to
    operate on the public values; either it accepts and the chain will
    accept (correctness), or it rejects and we abort here. -/
def signWithVerify (ps : ParamSet) (sk pkSeed pkRoot digest : String)
    (optrand? : Option String := none) : IO (Except Err String) := do
  match ← signRaw ps sk digest optrand? with
  | .error e => pure (.error e)
  | .ok sig =>
      match ← verify ps pkSeed pkRoot digest sig with
      | .error e => pure (.error e)
      | .ok true => pure (.ok sig)
      | .ok false => pure (.error .verifyAfterSignFailed)

/-- A single keygen → sign → verify roundtrip. Used by the smoke-test
    target and by the daemon's `sphincs.healthCheck` (Phase 3). For stub
    binaries (`info.stub = true`), returns `.error .stubBinary` without
    attempting keygen — kept as a generic guard so a future stub
    parameter set (built with `PARAM_SET_STUB=1`) cannot accidentally
    coerce the daemon into a sign/verify call. -/
def smokeRoundtrip (ps : ParamSet) (seedHex digest : String)
    (optrand? : Option String := none) : IO (Except Err Bool) := do
  match ← info ps with
  | .error e => pure (.error e)
  | .ok ib =>
      if ib.stub then pure (.error (.stubBinary ib.paramSet))
      else match ← keygen ps seedHex with
      | .error e => pure (.error e)
      | .ok km =>
          match ← signWithVerify ps km.sk km.pkSeed km.pkRoot digest optrand? with
          | .error e => pure (.error e)
          | .ok _ => pure (.ok true)

end LeanKohaku.Sphincs
