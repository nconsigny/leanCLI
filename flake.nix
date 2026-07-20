{
  description = "leanCLI — formally modeled Ethereum wallet (Lean 4 core, CLI + daemons + native crypto helpers)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Provides the exact Lean toolchain named in ./lean-toolchain
    # (leanprover/lean4:v4.29.1) as a nixpkgs overlay — no elan, no
    # version drift against whatever `pkgs.lean4` happens to be.
    lean4-nix = {
      url = "github:lenianiva/lean4-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Upstream sources for the native crypto helpers, pinned to the SAME
    # revisions as ops/scripts/setup_hacl.sh / setup_secp256k1.sh (keep
    # in lockstep). Flake inputs instead of build-time `git clone` so the
    # sandboxed build works offline; the flake.lock carries the hashes.
    hacl-packages = {
      url = "github:cryspen/hacl-packages/05c3d8fb321ed65e3db3a6a8b853019e86fb40a2";
      flake = false;
    };
    secp256k1 = {
      url = "github:bitcoin-core/secp256k1/1a53f4961f337b4d166c25fce72ef0dc88806618";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, lean4-nix, hacl-packages, secp256k1 }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          overlays = [ (lean4-nix.readToolchainFile ./lean-toolchain) ];
        }));
    in
    {
      packages = forAllSystems (pkgs: rec {
        native-helpers = pkgs.callPackage ./nix/native-helpers.nix {
          haclSrc = hacl-packages;
          secpSrc = secp256k1;
        };
        leancli = pkgs.callPackage ./nix/package.nix {
          lean = pkgs.lean.lean-all;
          nativeHelpers = native-helpers;
        };
        default = leancli;
      });

      # `services.leancli` — see nix/module.nix and docs/NIXOS.md.
      nixosModules = rec {
        leancli = import ./nix/module.nix self;
        default = leancli;
      };

      overlays.default = final: _prev: {
        leancli = self.packages.${final.stdenv.hostPlatform.system}.default;
      };

      apps = forAllSystems (pkgs:
        let system = pkgs.stdenv.hostPlatform.system; in rec {
          leancli = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/leancli";
          };
          daemon = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/leancli-daemon";
          };
          default = leancli;
        });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.lean.lean-all # exact toolchain from ./lean-toolchain
            pkgs.git
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
            pkgs.cargo
            pkgs.rustc
            pkgs.nodejs # sidecars + TUI (not part of the Nix package)
            pkgs.curl.dev
            pkgs.sqlite.dev

            # Optional host-integration tools. The Lean code does not link
            # to these packages; they are for provisioning and inspection.
            pkgs.tpm2-tools
            pkgs.libfido2
            pkgs.fprintd
          ];
          # NixOS has no /usr/lib/libcurl.so — pass the store paths into
          # the lakefile's -K overrides (see lakefile.lean, docs/NIXOS.md).
          shellHook = ''
            export LEANCLI_SYS_LIBS="-L${pkgs.lib.getLib pkgs.curl}/lib -L${pkgs.lib.getLib pkgs.sqlite}/lib -lcurl -lsqlite3 -Wl,--allow-shlib-undefined"
            export LEANCLI_SYS_INCLUDES="-I${pkgs.lib.getDev pkgs.curl}/include -I${pkgs.lib.getDev pkgs.sqlite}/include"
            echo 'leanCLI dev shell — build with:'
            echo '  lake "-KsysLibs=$LEANCLI_SYS_LIBS" "-KsysIncludes=$LEANCLI_SYS_INCLUDES" build'
          '';
        };
      });
    };
}
