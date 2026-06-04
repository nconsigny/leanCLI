{
  description = "leanCLI Lean wallet daemon";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          package = import ./default.nix { inherit pkgs; };
        in
        {
          default = package;
          leancli = package;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/leancli";
        };
        daemon = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/leancli-daemon";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.git
              pkgs.lean4
              pkgs.cmake
              pkgs.ninja
              pkgs.clang

              # Optional host-integration tools. The Lean code does not link
              # to these packages; they are for provisioning and inspection.
              pkgs.tpm2-tools
              pkgs.libfido2
              pkgs.fprintd
            ];
          };
        });
    };
}
