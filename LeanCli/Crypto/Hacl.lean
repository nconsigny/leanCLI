import LeanCli.Crypto.Hex

/-!
# Native cryptographic boundary

Hash/KDF/AEAD operations are intentionally modeled as a narrow external
boundary. The primary implementation is HACL*/hacl-packages from Project
Everest. HACL exposes raw Keccak with arbitrary delimiter; Ethereum uses
delimiter `0x01`, not FIPS-202 SHA3's `0x06`.

RIPEMD-160 is provided by a separate RustCrypto `ripemd` helper because the
pinned HACL package does not expose RIPEMD-160. It is used for BIP-32 HASH160
fingerprints, not Ethereum address derivation.

The wallet core proves it only asks for typed hashes/signatures. Functional
correctness of these primitives is delegated to the native helper boundary and
standard cryptographic assumptions.
-/

namespace LeanCli.Crypto.Hacl

opaque keccak256Ethereum : ByteArray → ByteArray

opaque sha256 : ByteArray → ByteArray

opaque hmacSha512 : ByteArray → ByteArray → ByteArray

opaque ripemd160 : ByteArray → ByteArray

opaque pbkdf2HmacSha512 : ByteArray → ByteArray → Nat → Nat → ByteArray

opaque chacha20Poly1305Seal : ByteArray → ByteArray → ByteArray → ByteArray → ByteArray

opaque chacha20Poly1305Open : ByteArray → ByteArray → ByteArray → ByteArray → Option ByteArray

def ethereumKeccakDelimiter : UInt8 := 0x01

def helperKeccak : String := "leancli-hacl-keccak256"
def helperSha256 : String := "leancli-hacl-sha256"
def helperHmacSha512 : String := "leancli-hacl-hmac-sha512"
def helperRipemd160 : String := "leancli-hacl-ripemd160"
def helperPbkdf2 : String := "leancli-hacl-pbkdf2"
def helperChacha20Poly1305 : String := "leancli-hacl-chacha20poly1305"

/-- Resolve a `leancli-hacl-*` helper binary.

Why this exists: `leanclispawn` only symlinks `leancli` and `leancli-daemon`
into `~/.leancli/bin/`. The helper binaries sit alongside the daemon at
`.lake/build/bin/`, and the kernel resolves `/proc/self/exe` through the
symlink — so `IO.appDir` is the directory that actually holds them, even
though that directory is not on the shell's `$PATH`. Try the absolute
path next to the running binary first; fall back to a bare-name lookup
through `$PATH` (so system-installed builds — Arch, Nix — that drop the
helpers in `/usr/bin` keep working). -/
private def resolveHelper (cmd : String) : IO String := do
  try
    let next := (← IO.appDir) / cmd
    if ← next.pathExists then pure next.toString else pure cmd
  catch _ => pure cmd

def runHexHelper (cmd : String) (args : Array String) : IO (Except String ByteArray) := do
  try
    let resolved ← resolveHelper cmd
    let out ← IO.Process.output { cmd := resolved, args := args }
    if out.exitCode == 0 then
      match LeanCli.Crypto.Hex.decode out.stdout.trimAscii.toString with
      | some bytes => pure (.ok bytes)
      | none => pure (.error s!"{cmd} returned non-hex output")
    else
      pure (.error out.stderr)
  catch e =>
    -- The most common failure here is ENOENT — the helper binary is
    -- absent because `script/setup_hacl.sh` / `script/setup_secp256k1.sh`
    -- never ran on this tree. The daemon precheck normally catches that
    -- at boot, but a helper deleted after boot, or a helper invoked
    -- outside the daemon (CLI tools), can still land here. Include the
    -- recovery command in every error so the message is actionable
    -- wherever it surfaces.
    pure (.error
      s!"{cmd}: {e.toString}; rebuild with `lake script run setup-helpers`")

def keccak256EthereumIO (inputHex : String) : IO (Except String ByteArray) :=
  runHexHelper helperKeccak #[inputHex]

def sha256IO (inputHex : String) : IO (Except String ByteArray) :=
  runHexHelper helperSha256 #[inputHex]

def hmacSha512IO (keyHex msgHex : String) : IO (Except String ByteArray) :=
  runHexHelper helperHmacSha512 #[keyHex, msgHex]

def ripemd160IO (inputHex : String) : IO (Except String ByteArray) :=
  runHexHelper helperRipemd160 #[inputHex]

def pbkdf2HmacSha512IO (passwordHex saltHex : String) (iters dkLen : Nat) :
    IO (Except String ByteArray) :=
  runHexHelper helperPbkdf2 #[passwordHex, saltHex, toString iters, toString dkLen]

def chacha20Poly1305SealIO (keyHex nonceHex aadHex payloadHex : String) :
    IO (Except String ByteArray) :=
  runHexHelper helperChacha20Poly1305 #["seal", keyHex, nonceHex, aadHex, payloadHex]

def chacha20Poly1305OpenIO (keyHex nonceHex aadHex payloadHex : String) :
    IO (Except String ByteArray) :=
  runHexHelper helperChacha20Poly1305 #["open", keyHex, nonceHex, aadHex, payloadHex]

end LeanCli.Crypto.Hacl
