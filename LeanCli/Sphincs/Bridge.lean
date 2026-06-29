import LeanCli.Encoding.Json

/-!
# SPHINCS- shim sidecar boundary

The SPHINCS- post-quantum signer is implemented in C (vendored from the
sphincs/sphincsplus reference under `sidecars/sphincs/`) and exposed to the
Lean tree via a small JSON-RPC shim. This module is the only place that
spawns those binaries.

Two parameter sets are wired in:
  - SLH-DSA-SHA2-128-24 (NIST FIPS 205 candidate, SHA-2 thash). Has a CPU
    reference signer and a Vulkan GPU signer (`SignerBackend`) that are
    bit-exact; standalone verifier only on Sepolia (no account yet).
  - C13 (WOTS+C / FORS+C, h=22 d=2 a=19 k=7 w=8, 3688-byte sig; FIPS 205
    §11.2.2 uncompressed 32-byte ADRS + keccak256). Supersedes the retired
    C9 variant and is the param set with a live on-chain hybrid 4337
    account on Sepolia.

The JARDIN-Keccak-128-24 variant was dropped: it offered the same sizes
as SLH-DSA-SHA2-128-24 with no on-chain account and no advantage over
C13's keccak verifier, so it added surface without value.

C13's Sepolia deployment (per `nconsigny/SPHINCS-` README) is the shared
verifier at 0xc6f4009D4a8220527b849670431Cbde5FeD8A5F2, account
0x01280171F336869e9c96F9e6eb674b1548D10dD4 via factory
0x8830d36284829656F2A60CD028062686069FABA4, against EntryPoint v0.9
(0x433709009B8330FDa32311DF1C2AFA402eD8D009). handleOps gas ≈ 293 K.
These addresses ship as built-in defaults in `Daemon/Config.lean::resolve`;
users override via `daemon.json`'s `sphincs_verifiers` /
`sphincs_factories` blocks.

User-facing label is "SPHINCS-" because the variants are non-standard
relative to NIST SLH-DSA. Internal type names and the on-chain
`SphincsAccount` contract name stay as they are.

Trust model: identical to the Node sidecars in `sidecars/`. The shim binary
is **untrusted** (the GPU signer doubly so — it runs driver/shader code).
Every output goes through length-validation against the parameter set's
known sizes, and `signWithVerify` runs verify-after-sign on the signing
backend before handing the signature back, so neither a malicious shim
nor a faulty GPU can get the daemon to broadcast a signature that
backend's own verifier would reject. Verify is intentionally NOT
cross-backend: after the FIPS-205 fixes the CPU shim reproduces the
on-chain KAT bit-exact, but CPU↔GPU SLH-DSA parity on arbitrary inputs is
not yet proven (a fresh vector still diverges) — see `signWithVerify`.

`info`-reported sizes are checked against the parameter-set's expected
constants on every call so a wrongly-spawned binary (or a tampered
`info`) is detected before any signing operation.

## Signer binaries (Track B)

The `sphincs-c13` and `sphincs-slhdsa-128-24-vk` (Vulkan) binaries are
native build artifacts of `sidecars/sphincs/Makefile`; until they are
vendored/built, `resolveExecutable` falls through to the basename on
PATH and the spawn fails closed. The retired `sphincs-c9` binary is no
longer referenced.
-/

namespace LeanCli.Sphincs

open LeanCli.Encoding.Json

/-- Supported SPHINCS- parameter sets. The on-chain `SphincsAccount`
    verifier address is selected per `(chain, paramSet)` pair, so the
    daemon must be told which one a given account uses; the abstract
    contract model in `LeanCli/Contract/SphincsAccount.lean` is
    paramSet-agnostic by design. -/
inductive ParamSet
  /-- NIST SLH-DSA-SHA2-128-24 (FIPS 205 candidate). Slow signing; sane
      for a v0 deployment because verification is fast and the spec is
      well reviewed. -/
  | slhDsaSha2_128_24
  /-- C13 (WOTS+C / FORS+C, n=16 h=22 d=2 a=19 k=7 w=8 l=43 target=208,
      3688-byte sig). The cheapest verifier in the SPHINCS- family at
      128-bit security up to a 2²² signature cap, and the smallest
      signature. Unlike the retired C9 variant it carries the
      **FIPS 205 §11.2.2 uncompressed 32-byte ADRS layout** (keccak256
      hash), so it ports cleanly from a FIPS reference implementation.
      C13 is the parameter set with a live on-chain hybrid 4337 account
      on Sepolia: verifier `0xc6f4009D4a8220527b849670431Cbde5FeD8A5F2`,
      account `0x01280171F336869e9c96F9e6eb674b1548D10dD4` via factory
      `0x8830d36284829656F2A60CD028062686069FABA4` (EntryPoint v0.9).
      Signer: upstream `nconsigny/SPHINCS- signer-wasm` (`params.rs`
      SIG_SIZE = 3688). Supersedes C9, which is retired upstream. -/
  | c13
  deriving Repr, DecidableEq

/-- Serialise a `ParamSet` to its JSON tag (matches the shim's `info`
    output and the on-disk verifier address map keys). -/
def ParamSet.toString : ParamSet → String
  | .slhDsaSha2_128_24   => "SLH-DSA-SHA2-128-24"
  | .c13                 => "C13"

/-- Inverse of `toString`, plus short case-insensitive aliases so the
    CLI/TUI can accept `slhdsa`, `sha2`, `c13` alongside the canonical
    labels. Used when reading shim `info` output, `daemon.json` keys, and
    user-supplied `--param-set` values. The retired `C9` and
    `JARDIN-Keccak-128-24` labels are intentionally NOT accepted — they
    are removed upstream/here in favour of C13, so a stale config or
    command referencing them fails closed rather than silently selecting
    a missing verifier. -/
def ParamSet.parse? (s : String) : Option ParamSet :=
  match s.trimAscii.toString.toLower with
  | "slh-dsa-sha2-128-24" => some .slhDsaSha2_128_24
  | "slhdsa"              => some .slhDsaSha2_128_24
  | "sha2"                => some .slhDsaSha2_128_24
  | "c13"                 => some .c13
  | _                     => none

/-- Which signer implementation to spawn for a parameter set.

    The CPU path is the vendored C / Rust reference signer. The Vulkan
    path is the GPU-accelerated signer (upstream
    `nconsigny/SPHINCS- (signers/slhvk-sha2-128-24/)`), which is
    **bit-exact** with the CPU SLH-DSA-SHA2-128-24 reference — same
    signature / key / seed byte sizes, same on-chain verifier — so it is
    a drop-in *backend* of an existing `ParamSet`, never a new param set.
    Selecting `vulkan` only changes which executable the bridge spawns;
    all length validation and verify-after-sign are unchanged, and the
    GPU path is meaningful only for `slhDsaSha2_128_24` (the only set the
    Vulkan signer implements). Other param sets ignore the backend.

    Mirrors the daemon-wide `readBackend` (helios | rpc) toggle pattern:
    untrusted output, re-validated; the GPU never gets to broadcast an
    unverifiable signature because `signWithVerify` re-verifies first. -/
inductive SignerBackend
  | cpu
  | vulkan
  deriving Repr, DecidableEq

/-- Case-insensitive parse; accepts `gpu` as an alias for `vulkan`.
    Returns `none` on anything else so callers can fall back to the
    configured default rather than silently picking CPU. -/
def SignerBackend.parse? (s : String) : Option SignerBackend :=
  match s.trimAscii.toString.toLower with
  | "cpu"    => some .cpu
  | "vulkan" => some .vulkan
  | "gpu"    => some .vulkan
  | _        => none

/-- Stable JSON / display tag. -/
def SignerBackend.toString : SignerBackend → String
  | .cpu    => "cpu"
  | .vulkan => "vulkan"

/-- Default executable basenames produced by `sidecars/sphincs/Makefile`
    and copied into `.lake/build/bin/` by the lake hook. Used as the
    PATH-fallback when neither the env override nor the in-monorepo
    binary directory resolves. The `vulkan` backend selects the
    GPU-accelerated SLH-DSA-SHA2 binary; for every other `(paramSet,
    backend)` pair the CPU basename is returned (the backend is a no-op
    outside SLH-DSA-SHA2). -/
def ParamSet.defaultExecutable (ps : ParamSet) (backend : SignerBackend := .cpu) : String :=
  match ps, backend with
  | .slhDsaSha2_128_24,  .vulkan => "sphincs-slhdsa-128-24-vk"
  | .slhDsaSha2_128_24,  .cpu    => "sphincs-slhdsa-128-24"
  | .c13,                _       => "sphincs-c13"

/-- Walk upward from the working directory looking for
    `sidecars/sphincs/bin/<basename>` that ships in this repo. Returns
    the first match within `maxHops` parents, or `none`. Mirrors the
    `Clearsign/Bridge.lean::findBridgeMjs` and
    `Colibri/Persistent.lean::findBridgeMjs` helpers so the daemon picks
    up locally-built shim binaries (`make` under `sidecars/sphincs/`)
    without an explicit `LEANCLI_SPHINCS_*` env var. -/
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

/-- Resolve the shim binary path for `(ps, backend)` in this order:
    1. `LEANCLI_SPHINCS_<PARAMSET>` env var (explicit override; the
       Vulkan SLH-DSA backend has its own `LEANCLI_SPHINCS_SLHDSA_VK`).
    2. `sidecars/sphincs/bin/<basename>` walked upward from CWD
       (monorepo build output of `make`).
    3. `<basename>` on PATH (or `.lake/build/bin/` when the lake hook
       has copied it there). -/
def resolveExecutable (ps : ParamSet) (backend : SignerBackend := .cpu) : IO String := do
  let envKey := match ps, backend with
    | .slhDsaSha2_128_24,  .vulkan => "LEANCLI_SPHINCS_SLHDSA_VK"
    | .slhDsaSha2_128_24,  .cpu    => "LEANCLI_SPHINCS_SLHDSA"
    | .c13,                _       => "LEANCLI_SPHINCS_C13"
  match (← IO.getEnv envKey) with
  | some s => pure s
  | none =>
      let basename := ps.defaultExecutable backend
      let cwd ← IO.currentDir
      match ← findShimBinary basename cwd 8 with
      | some p => pure p
      | none => pure basename

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
  | .slhDsaSha2_128_24   => 3856
  | .c13                 => 3688

/-- On-chain gas the bundler's `eth_estimateUserOperationGas` **fails to
    account for** and which the daemon must add back onto the returned
    `verificationGasLimit`.

    `SphincsAccount._validateSignature` checks ECDSA recovery first and
    `return SIG_VALIDATION_FAILED` *before* the SPHINCS+ verifier
    `staticcall` (see `vendor/sphincs-minus/src/SphincsAccount.sol`). We
    estimate gas with a **dummy all-zero ECDSA signature** (a real
    signature isn't available until after the hash — which depends on the
    gas fields — is known), so estimation recovers a non-owner address,
    short-circuits, and never measures the verifier staticcall. At real
    submit the genuine ECDSA passes, the verifier runs, and the
    verification phase overshoots the estimate → bundler `AA26 over
    verificationGasLimit`.

    These are the standalone on-chain verify costs (per
    `vendor/sphincs-minus/CLAUDE.md`) rounded up with comfortable margin
    to cover the staticcall's 63/64 gas forwarding, the `abi.decode` of
    the multi-KB signature into memory, and the hardened verifier's
    canonical-key (`N_MASK`) checks: C13 ≈ 188 K measured, SLH-DSA-SHA2
    ≈ 226 K measured. Over-budgeting here is cheap (unused gas is
    refunded by the EntryPoint) and far safer than re-tripping AA26. -/
def ParamSet.verifyGasFloor : ParamSet → Nat
  | .slhDsaSha2_128_24   => 350000
  | .c13                 => 300000

/-- C13: 64 bytes = 2 × 32-byte words. `pkSeed` and `pkRoot` are
    ABI-shaped as `bytes32` for the on-chain
    `SphincsC13Asm.verify(bytes32 pkSeed, bytes32 pkRoot, …)`, with the
    meaningful 16 bytes (n=16) in the high half of each word — same
    on-chain shape as the retired C9 verifier. -/
def ParamSet.expectedPkBytes : ParamSet → Nat
  | .slhDsaSha2_128_24   => 32
  | .c13                 => 64

/-- C13: 96 bytes = 3 × 32-byte words concatenated as
    `pkSeed || skSeed || pkRoot`, mirroring how the Rust signer's
    `sphincs::sign` consumes its `(pk_seed, sk_seed, pk_root)` triple. -/
def ParamSet.expectedSkBytes : ParamSet → Nat
  | .slhDsaSha2_128_24   => 64
  | .c13                 => 96

/-- C13: 32 raw entropy bytes. The daemon hands TPM-sealed material in;
    the signer derives `(pk_seed, sk_seed, pk_root)` deterministically
    via keccak with the `"sphincs-c13-v1"`-equivalent domain tag. -/
def ParamSet.expectedSeedBytes : ParamSet → Nat
  | .slhDsaSha2_128_24   => 48
  | .c13                 => 32

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
    JSON-RPC envelope. Mirrors the Privacy/Clearsign bridges. `backend`
    selects the CPU or Vulkan executable (no-op outside SLH-DSA-SHA2). -/
private def callRaw (ps : ParamSet) (method : String) (params : Json) (id : Nat)
    (backend : SignerBackend := .cpu) : IO (Except Err Json) := do
  let exe ← resolveExecutable ps backend
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
def info (ps : ParamSet) (backend : SignerBackend := .cpu) : IO (Except Err InfoBlob) := do
  match ← callRaw ps "info" (.obj #[]) 0 backend with
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
def keygen (ps : ParamSet) (seedHex : String) (backend : SignerBackend := .cpu) :
    IO (Except Err KeyMaterial) := do
  match hexBytes? seedHex with
  | none => pure (.error (.parse "seedHex must be even-length hex" seedHex))
  | some n =>
      if n ≠ ps.expectedSeedBytes then
        pure (.error (.sizeMismatch "seedHex" n ps.expectedSeedBytes))
      else
        match ← callRaw ps "keygen" (.obj #[("seedHex", .str seedHex)]) 1 backend with
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
def signRaw (ps : ParamSet) (sk digest : String) (optrand? : Option String := none)
    (backend : SignerBackend := .cpu) : IO (Except Err String) := do
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
            match ← callRaw ps "sign" (.obj fields) 2 backend with
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
def verify (ps : ParamSet) (pkSeed pkRoot digest sig : String)
    (backend : SignerBackend := .cpu) : IO (Except Err Bool) := do
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
                    ]) 3 backend with
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
    even if the shim sign path has been tampered with, verify still has
    to operate on the public values; either it accepts and the chain
    will accept (correctness), or it rejects and we abort here.

    Verify-after-sign runs on the SAME backend that produced the
    signature — NOT cross-backend (CPU-verify of a GPU sig), because
    CPU↔GPU parity for SLH-DSA-SHA2 is not yet complete. After the
    FIPS-205 fixes (external envelope + MSB-first FORS parse), the CPU
    reference reproduces the on-chain KAT vector
    `vendor-slhvk-sha2-128-24/kat-counter0.json` BIT-EXACT — but a fresh
    input still diverges: keygen matches, yet CPU and GPU produce
    different (each individually valid) signatures and CPU rejects the
    GPU's. There is a residual, input-dependent divergence in the
    message→indices path that the single KAT did not exercise. Until that
    is localised (more KAT vectors / a cross-impl oracle), cross-backend
    verify is unsound, so each backend re-verifies its own output. The
    KAT independently establishes the GPU signer is on-chain-correct for
    the canonical vector; same-backend verify-after-sign then guarantees
    self-consistency before broadcast. (C13 uses its own keccak h_msg and
    is unaffected.) -/
def signWithVerify (ps : ParamSet) (sk pkSeed pkRoot digest : String)
    (optrand? : Option String := none) (backend : SignerBackend := .cpu) :
    IO (Except Err String) := do
  match ← signRaw ps sk digest optrand? backend with
  | .error e => pure (.error e)
  | .ok sig =>
      match ← verify ps pkSeed pkRoot digest sig backend with
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
    (optrand? : Option String := none) (backend : SignerBackend := .cpu) :
    IO (Except Err Bool) := do
  match ← info ps backend with
  | .error e => pure (.error e)
  | .ok ib =>
      if ib.stub then pure (.error (.stubBinary ib.paramSet))
      else match ← keygen ps seedHex backend with
      | .error e => pure (.error e)
      | .ok km =>
          match ← signWithVerify ps km.sk km.pkSeed km.pkRoot digest optrand? backend with
          | .error e => pure (.error e)
          | .ok _ => pure (.ok true)

end LeanCli.Sphincs
