# Native crypto helper binaries (`leancli-hacl-*`, `leancli-secp256k1-*`)
# the wallet daemon shells out to for every PBKDF2 / HMAC / Keccak /
# ChaCha20-Poly1305 / ECDSA op.
#
# This is the Nix-sandbox equivalent of ops/scripts/setup_hacl.sh and
# ops/scripts/setup_secp256k1.sh: same upstream projects, same pinned
# revisions, but the sources arrive as flake inputs (see flake.nix)
# instead of `git clone`, so the build works offline. Keep the revs here
# and in the two setup scripts in lockstep.
{ lib
, stdenv
, cmake
, ninja
, python3
, rustPlatform
, haclSrc # cryspen/hacl-packages source tree, pinned in flake.nix
, secpSrc # bitcoin-core/secp256k1 source tree, pinned in flake.nix
}:

let
  hacl = stdenv.mkDerivation {
    pname = "hacl-packages";
    version = "unstable-05c3d8fb";
    src = haclSrc;
    nativeBuildInputs = [ cmake ninja python3 ];
    cmakeFlags = [
      "-DENABLE_TESTS=OFF"
      "-DENABLE_BENCHMARKS=OFF"
    ];
    # Some hacl-packages revisions generate config.h under the cmake
    # build dir but install from <src>/build/config.h. The nixpkgs cmake
    # hook already builds in <src>/build, so the file lands where the
    # install step expects it — no workaround needed (unlike
    # setup_hacl.sh, which configures an out-of-tree dir).
  };

  secp256k1 = stdenv.mkDerivation {
    pname = "secp256k1";
    version = "unstable-1a53f496";
    src = secpSrc;
    nativeBuildInputs = [ cmake ninja ];
    cmakeFlags = [
      "-DSECP256K1_ENABLE_MODULE_RECOVERY=ON"
      "-DSECP256K1_BUILD_TESTS=OFF"
      "-DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF"
      "-DSECP256K1_BUILD_BENCHMARK=OFF"
      "-DSECP256K1_BUILD_CTIME_TESTS=OFF"
    ];
  };

  # RIPEMD-160 helper (RustCrypto — HACL does not expose RIPEMD-160; it
  # backs BIP-32 HASH160 only). Cargo.lock carries crates.io checksums,
  # so no cargoHash is needed.
  rustcryptoHelpers = rustPlatform.buildRustPackage {
    pname = "leancli-rustcrypto-helpers";
    version = "0.1.0";
    src = lib.cleanSourceWith {
      src = ../native/rustcrypto_helpers;
      filter = path: _type: baseNameOf path != "target";
    };
    cargoLock.lockFile = ../native/rustcrypto_helpers/Cargo.lock;
  };
in
stdenv.mkDerivation {
  pname = "leancli-native-helpers";
  version = "0.1.0";

  src = lib.cleanSource ../native;

  buildInputs = [ hacl secp256k1 ];

  # The cc/ld wrappers add RPATH entries for the -L store dirs, so the
  # helpers resolve libhacl.so / libsecp256k1.so at runtime without any
  # patchelf step (same role as the -Wl,-rpath in the setup scripts).
  buildPhase = ''
    runHook preBuild
    mkdir -p bin

    build_hacl_helper() {
      $CC -O2 \
        -Ihacl_helpers \
        -I${hacl}/include \
        -I${hacl}/include/hacl \
        -I${haclSrc}/include \
        -I${haclSrc}/karamel/include \
        "$1" \
        -L${hacl}/lib -lhacl \
        -o "$2"
    }

    build_hacl_helper hacl_helpers/hacl_keccak256.c        bin/leancli-hacl-keccak256
    build_hacl_helper hacl_helpers/hacl_sha256.c           bin/leancli-hacl-sha256
    build_hacl_helper hacl_helpers/hacl_hmac_sha512.c      bin/leancli-hacl-hmac-sha512
    build_hacl_helper hacl_helpers/hacl_pbkdf2_sha512.c    bin/leancli-hacl-pbkdf2
    build_hacl_helper hacl_helpers/hacl_chacha20poly1305.c bin/leancli-hacl-chacha20poly1305

    build_secp_helper() {
      $CC -O2 \
        -Isecp256k1_helpers \
        -Ihacl_helpers \
        -I${secp256k1}/include \
        "$1" \
        -L${secp256k1}/lib -lsecp256k1 \
        -o "$2"
    }

    build_secp_helper secp256k1_helpers/secp256k1_sign.c    bin/leancli-secp256k1-sign
    build_secp_helper secp256k1_helpers/secp256k1_pubkey.c  bin/leancli-secp256k1-pubkey
    build_secp_helper secp256k1_helpers/secp256k1_recover.c bin/leancli-secp256k1-recover
    build_secp_helper secp256k1_helpers/secp256k1_verify.c  bin/leancli-secp256k1-verify
    runHook postBuild
  '';

  # Mirrors ops/scripts/check_native_helpers.sh so a broken helper fails
  # the build, not the daemon's boot precheck later.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    [ "$(bin/leancli-hacl-sha256 abcd)" = \
      "0x123d4c7ef2d1600a1b3a0f6addc60a10f05a3495c9409f2ecbf4cc095d000a6b" ]
    [ "$(bin/leancli-secp256k1-pubkey \
      0000000000000000000000000000000000000000000000000000000000000001 compressed)" = \
      "0x0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" ]
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 -t "$out/bin" bin/*
    install -Dm755 ${rustcryptoHelpers}/bin/leancli-hacl-ripemd160 \
      "$out/bin/leancli-hacl-ripemd160"
    runHook postInstall
  '';

  passthru = { inherit hacl secp256k1 rustcryptoHelpers; };

  meta = {
    description = "Process-isolated crypto helper binaries for the leanCLI wallet daemon";
    platforms = lib.platforms.linux;
  };
}
