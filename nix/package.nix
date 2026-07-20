# Main leancli derivation: Lean library + CLI + wallet daemon + agent
# binaries, with the native crypto helpers installed alongside the
# daemon (LeanCli.Crypto.Hacl resolves helpers from the running
# binary's own directory first, so `$out/bin` is exactly where they
# must live).
#
# Deliberately NOT packaged here (network-dependent npm installs):
#   - the Ink/React TUI (tui/) — the CLI surface is fully functional
#     without it;
#   - the Node sidecars (sidecars/kohaku, sidecars/clearsign) — so the
#     helios/colibri providers and privacy plugins are unavailable from
#     this package; the NixOS module defaults LEANCLI_PROVIDER=rpc.
{ lib
, stdenv
, lean # package putting `lean`, `leanc`, `lake` on PATH (flake: pkgs.lean.lean-all)
, git
, curl
, sqlite
, gmp
, libuv
, nativeHelpers # nix/native-helpers.nix
, autoPatchelfHook
, withSphincsShims ? true
}:

stdenv.mkDerivation {
  pname = "leancli";
  version = "0.1.0";

  src = lib.cleanSourceWith {
    src = ./..;
    filter = path: type:
      lib.cleanSourceFilter path type
      && !(builtins.elem (baseNameOf path) [
        ".lake" ".leancli" ".leankohaku" "node_modules" "target"
        "result" "cache" "dist"
      ]);
  };

  nativeBuildInputs = [ lean git autoPatchelfHook ];

  # curl/sqlite: linked by liblean_http / liblean_sqlite. lean/gmp/libuv:
  # runtime libs of `supportInterpreter := true` executables
  # (libleanshared + its deps) — autoPatchelf resolves DT_NEEDED against
  # these. nativeHelpers' libs cover the symlinked helper binaries.
  buildInputs = [
    curl
    sqlite
    lean
    gmp
    libuv
    nativeHelpers.hacl
    nativeHelpers.secp256k1
  ];

  # The helper binaries are symlinks into nativeHelpers (already
  # correctly rpath'd); missing-dep hard failures are disabled because
  # the Lean toolchain layout varies across lean4-nix/nixpkgs — patch
  # what resolves, leave the rest to the wrappers' rpaths.
  autoPatchelfIgnoreMissingDeps = true;

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"

    # sysLibs/sysIncludes: see lakefile.lean — NixOS has no /usr/lib, so
    # the Linux link line and shim header dirs are store paths here. The
    # ld wrapper turns the -L store dirs into RPATH entries.
    lake \
      "-KsysLibs=-L${lib.getLib curl}/lib -L${lib.getLib sqlite}/lib -lcurl -lsqlite3 -Wl,--allow-shlib-undefined" \
      "-KsysIncludes=-I${lib.getDev curl}/include -I${lib.getDev sqlite}/include" \
      build leancli leancli-daemon leancli_agent leancli_agentd

    ${lib.optionalString withSphincsShims ''
      # C parameter sets only: `make c9` is a cargo build with no vendored
      # crate cache, so it cannot run in the sandbox. Non-fatal, matching
      # the `lake script run sphincs-shims` skip-on-failure policy.
      make -C sidecars/sphincs OUT_DIR="$PWD/.lake/build/bin" slhdsa jardin \
        || echo "[sphincs-shims] build failed (non-fatal); continuing"
    ''}
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 .lake/build/bin/leancli "$out/bin/leancli"
    install -Dm755 .lake/build/bin/leancli-daemon "$out/bin/leancli-daemon"
    # Lake target names use underscores; the canonical install names are
    # dashed (LlmAgent/Bridge.lean resolves `leancli-agent` on $PATH).
    install -Dm755 .lake/build/bin/leancli_agent "$out/bin/leancli-agent"
    install -Dm755 .lake/build/bin/leancli_agentd "$out/bin/leancli-agentd"
    # Short alias users type interactively → the single leancli binary. The
    # CLI reads argv[0] and renders help/usage as `kohaku` when invoked so.
    ln -s leancli "$out/bin/kohaku"

    # Crypto helpers next to the daemon — the boot precheck and
    # resolveHelper look in the daemon's own directory first.
    for helper in ${nativeHelpers}/bin/*; do
      ln -s "$helper" "$out/bin/$(basename "$helper")"
    done

    for shim in .lake/build/bin/sphincs-*; do
      if [ -f "$shim" ]; then
        install -Dm755 "$shim" "$out/bin/$(basename "$shim")"
      fi
    done

    # Agent skills tree; point LEANCLI_SKILLS_DIR here (the NixOS module
    # does) — the daemon default is <cwd>/skills, useless for a store
    # install.
    mkdir -p "$out/share/leancli"
    cp -r skills "$out/share/leancli/skills"

    # Shell completion, generated from the binary so it tracks whatever
    # commands the build actually exposes. Best-effort: the binary needs
    # its shared libs before autoPatchelf has run, hence the explicit
    # LD_LIBRARY_PATH; if the toolchain layout defeats it we lose
    # completions, not the package.
    export LD_LIBRARY_PATH="${lib.getLib curl}/lib:${lib.getLib sqlite}/lib:${lean}/lib:${lean}/lib/lean''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    if "$out/bin/leancli" completion bash > leancli.bash 2>/dev/null; then
      install -Dm644 leancli.bash "$out/share/bash-completion/completions/leancli"
      ln -s leancli "$out/share/bash-completion/completions/kohaku"
      "$out/bin/leancli" completion zsh > _leancli
      install -Dm644 _leancli "$out/share/zsh/site-functions/_leancli"
      ln -s _leancli "$out/share/zsh/site-functions/_kohaku"
    else
      echo "[leancli] completion generation skipped (binary not runnable pre-fixup)"
    fi

    # Reference user units, ExecStart retargeted from ~/.leancli/bin
    # into the store. On NixOS prefer services.leancli (nix/module.nix),
    # which defines proper systemd.user services.
    install -Dm644 ops/packaging/systemd/leancli-daemon.service \
      "$out/lib/systemd/user/leancli-daemon.service"
    install -Dm644 ops/packaging/systemd/leancli-agentd.service \
      "$out/lib/systemd/user/leancli-agentd.service"
    substituteInPlace "$out/lib/systemd/user/leancli-daemon.service" \
      --replace-fail "%h/.leancli/bin/leancli-daemon" "$out/bin/leancli-daemon"
    substituteInPlace "$out/lib/systemd/user/leancli-agentd.service" \
      --replace-fail "%h/.leancli/bin/leancli-agentd" "$out/bin/leancli-agentd"

    install -Dm644 README.md "$out/share/doc/leancli/README.md"
    install -Dm644 INVARIANTS.md "$out/share/doc/leancli/INVARIANTS.md"
    install -Dm644 SECURITY.md "$out/share/doc/leancli/SECURITY.md"
    install -Dm644 docs/CLI.md "$out/share/doc/leancli/CLI.md"
    install -Dm644 docs/DAEMON.md "$out/share/doc/leancli/DAEMON.md"
    install -Dm644 docs/PRIVACY_SECURITY.md "$out/share/doc/leancli/PRIVACY_SECURITY.md"
    install -Dm644 docs/NIXOS.md "$out/share/doc/leancli/NIXOS.md"
    runHook postInstall
  '';

  passthru = {
    inherit nativeHelpers;
    leanToolchain = builtins.readFile ../lean-toolchain;
    optionalSystemIntegration = [
      "tpm2-tools"
      "libfido2"
      "fprintd"
    ];
  };

  meta = {
    description = "Formally modeled Ethereum wallet daemon written in Lean 4";
    longDescription = ''
      leanCLI builds the Lean library, CLI, wallet daemon, and agent
      daemon, plus the process-isolated HACL*/secp256k1 helper binaries
      the daemon shells out to for crypto. The Node sidecars (helios /
      colibri light-client providers, privacy plugins, TUI) are not part
      of this package; the daemon runs with the direct-RPC provider.
      tpm2-tools, libfido2, and fprintd are optional operator tooling
      for host provisioning and testing.
    '';
    mainProgram = "leancli";
    platforms = lib.platforms.linux;
  };
}
