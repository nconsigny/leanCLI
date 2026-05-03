{ pkgs ? import <nixpkgs> { } }:

pkgs.stdenv.mkDerivation rec {
  pname = "leankohaku";
  version = "0.1.0";

  src = pkgs.lib.cleanSource ./.;

  nativeBuildInputs = [
    pkgs.git
    pkgs.lean4
    pkgs.cmake
    pkgs.ninja
    pkgs.clang
  ];

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    lake build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 .lake/build/bin/leankohaku "$out/bin/leankohaku"
    install -Dm755 .lake/build/bin/leankohaku-daemon "$out/bin/leankohaku-daemon"
    install -Dm644 packaging/systemd/leankohaku.socket "$out/lib/systemd/user/leankohaku.socket"
    install -Dm644 packaging/systemd/leankohaku.service "$out/lib/systemd/user/leankohaku.service"
    install -Dm644 README.md "$out/share/doc/leankohaku/README.md"
    install -Dm644 INVARIANTS.md "$out/share/doc/leankohaku/INVARIANTS.md"
    install -Dm644 SECURITY.md "$out/share/doc/leankohaku/SECURITY.md"
    install -Dm644 docs/CLI.md "$out/share/doc/leankohaku/CLI.md"
    install -Dm644 docs/DAEMON.md "$out/share/doc/leankohaku/DAEMON.md"
    install -Dm644 docs/PRIVACY_SECURITY.md "$out/share/doc/leankohaku/PRIVACY_SECURITY.md"
    install -Dm644 docs/R1_SEPOLIA.md "$out/share/doc/leankohaku/R1_SEPOLIA.md"
    runHook postInstall
  '';

  passthru = {
    leanToolchain = builtins.readFile ./lean-toolchain;
    optionalSystemIntegration = [
      "tpm2-tools"
      "libfido2"
      "fprintd"
    ];
  };

  meta = with pkgs.lib; {
    description = "Formally modeled Ethereum wallet daemon written in Lean 4";
    longDescription = ''
      leanKohaku builds the Lean library, CLI, and daemon without linking TPM2,
      FIDO2, Secure Enclave, or other crypto/runtime FFI libraries into the
      wallet. Linux TPM2, FIDO2, and keyring support is currently modeled as a
      local policy boundary; system packages such as tpm2-tools, libfido2, and
      fprintd are optional operator tooling for host provisioning and testing.
      HACL Packages is the only accepted external crypto dependency and is
      wired through script/setup_hacl.sh rather than linked into the default
      Lean build.
    '';
    mainProgram = "leankohaku";
    platforms = platforms.linux;
  };
}
