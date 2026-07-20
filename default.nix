# Non-flake entry point (plain `nix-build`). Prefer the flake — it pins
# the exact Lean toolchain from ./lean-toolchain via lean4-nix and locks
# the helper-source hashes. This fallback uses whatever `lean4` your
# nixpkgs ships (check it against ./lean-toolchain if the Lean build
# errors) and fetches the helper sources with builtins.fetchGit, which
# needs network at eval time.
{ pkgs ? import <nixpkgs> { } }:

let
  nativeHelpers = pkgs.callPackage ./nix/native-helpers.nix {
    # Same pinned revs as ops/scripts/setup_hacl.sh /
    # setup_secp256k1.sh and flake.nix — keep all three in lockstep.
    haclSrc = builtins.fetchGit {
      url = "https://github.com/cryspen/hacl-packages.git";
      rev = "05c3d8fb321ed65e3db3a6a8b853019e86fb40a2";
      allRefs = true;
    };
    secpSrc = builtins.fetchGit {
      url = "https://github.com/bitcoin-core/secp256k1.git";
      rev = "1a53f4961f337b4d166c25fce72ef0dc88806618";
      allRefs = true;
    };
  };
in
pkgs.callPackage ./nix/package.nix {
  lean = pkgs.lean4;
  inherit nativeHelpers;
}
