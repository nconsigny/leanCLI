{ pkgs ? import <nixpkgs> { } }:

pkgs.stdenv.mkDerivation rec {
  pname = "leancli";
  version = "0.1.0";

  src = pkgs.lib.cleanSource ./.;

  nativeBuildInputs = [
    pkgs.git
    pkgs.lean4
    pkgs.cmake
    pkgs.ninja
    pkgs.clang
    pkgs.nodejs_20
  ];

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    lake build
    # TUI bundle (Ink/React → single esbuild output). Skipped silently if
    # tui/ is absent so the derivation still works for header-only checkouts.
    if [ -d tui ]; then
      ( cd tui && npm ci --offline --no-audit --no-fund 2>/dev/null || \
                  npm install --no-audit --no-fund )
      ( cd tui && npm run build )
    fi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 .lake/build/bin/leancli "$out/bin/leancli"
    install -Dm755 .lake/build/bin/leancli-daemon "$out/bin/leancli-daemon"
    # Short alias users type interactively → the single leancli binary. The
    # CLI reads argv[0] and renders help/usage as `kohaku` when invoked so.
    ln -s leancli "$out/bin/kohaku"

    # Shell completion, generated from the binary so it tracks whatever
    # commands the build actually exposes (no second source of truth).
    install -dm755 "$out/share/bash-completion/completions"
    "$out/bin/leancli" completion bash \
        > "$out/share/bash-completion/completions/leancli"
    # The generated script registers both `leancli` and `kohaku`; symlink so
    # bash autoloads it when the alias is first completed.
    ln -s leancli "$out/share/bash-completion/completions/kohaku"

    install -dm755 "$out/share/zsh/site-functions"
    "$out/bin/leancli" completion zsh \
        > "$out/share/zsh/site-functions/_leancli"
    ln -s _leancli "$out/share/zsh/site-functions/_kohaku"

    if [ -f tui/dist/index.mjs ]; then
      install -Dm644 tui/dist/index.mjs "$out/share/leancli/tui/index.mjs"
    fi

    install -Dm644 ops/packaging/systemd/leancli.socket "$out/lib/systemd/user/leancli.socket"
    install -Dm644 ops/packaging/systemd/leancli.service "$out/lib/systemd/user/leancli.service"
    install -Dm644 README.md "$out/share/doc/leancli/README.md"
    install -Dm644 INVARIANTS.md "$out/share/doc/leancli/INVARIANTS.md"
    install -Dm644 SECURITY.md "$out/share/doc/leancli/SECURITY.md"
    install -Dm644 docs/CLI.md "$out/share/doc/leancli/CLI.md"
    install -Dm644 docs/DAEMON.md "$out/share/doc/leancli/DAEMON.md"
    install -Dm644 docs/PRIVACY_SECURITY.md "$out/share/doc/leancli/PRIVACY_SECURITY.md"
    install -Dm644 docs/R1_SEPOLIA.md "$out/share/doc/leancli/R1_SEPOLIA.md"
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
      leanCLI builds the Lean library, CLI, and daemon without linking TPM2,
      FIDO2, Secure Enclave, or other crypto/runtime FFI libraries into the
      wallet. Linux TPM2, FIDO2, and keyring support is currently modeled as a
      local policy boundary; system packages such as tpm2-tools, libfido2, and
      fprintd are optional operator tooling for host provisioning and testing.
      HACL Packages is the only accepted external crypto dependency and is
      wired through ops/scripts/setup_hacl.sh rather than linked into the default
      Lean build.
    '';
    mainProgram = "leancli";
    platforms = platforms.linux;
  };
}
