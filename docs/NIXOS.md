# leanCLI on Nix / NixOS

The repo is a flake. It builds the Lean core (CLI, wallet daemon, agent
daemons), the HACL\*/secp256k1 crypto helper binaries, and the two C
SPHINCS+ shims — everything the daemon's boot precheck requires — inside
the Nix sandbox, with the exact Lean toolchain from `lean-toolchain`
(via [lean4-nix](https://github.com/lenianiva/lean4-nix)).

## Quick start

```bash
nix run github:nconsigny/leanCLI                # the CLI
nix build github:nconsigny/leanCLI && ./result/bin/leancli-daemon
```

From a checkout: `nix build .` (remember Nix only sees files known to
git — `git add` new files first).

## Running it on a NixOS config (e.g. davhau/nixos-example)

[davhau/nixos-example](https://github.com/davhau/nixos-example) wires
every machine as `nixpkgs.lib.nixosSystem { modules = [ ... ]; specialArgs
= { inherit inputs; }; }`, so integration is two edits:

**1. `flake.nix` — add the input:**

```nix
inputs.leancli = {
  url = "github:nconsigny/leanCLI";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

**2. `machines/<name>/configuration.nix` — import the module** (the
`inputs` argument is already available through `specialArgs`):

```nix
{ inputs, ... }:
{
  imports = [ inputs.leancli.nixosModules.default ];

  services.leancli = {
    enable = true;
    # agentDaemon.enable = true;              # LLM agent sessions
    # environment.LEANCLI_RPC_URL = "…";      # extra daemon env
  };
}
```

Then `nix flake lock` (pins leancli + its helper sources), `git add`
everything, and rebuild — `nixos-rebuild switch --flake .#<machine>`, or
any of the repo's image outputs (`v-vm` is the fastest way to try it in
a qemu VM).

After login on the target machine:

```bash
systemctl --user status leancli-daemon    # auto-started (autoStart=true)
leancli --help                            # CLI / `kohaku` alias
journalctl --user -u leancli-daemon -f
```

## Module options (`services.leancli`)

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | Installs the package + a systemd **user** service for the wallet daemon (UDS at `$XDG_RUNTIME_DIR/leancli/leancli.sock`). |
| `package` | this flake's build | Override to a custom build. |
| `provider` | `"rpc"` | `LEANCLI_PROVIDER`. Defaults to direct RPC because the Node sidecars are not packaged (below); upstream's default is `helios`. |
| `autoStart` | `true` | `WantedBy=default.target`. Set `false` for upstream's manual-start lifecycle. |
| `agentDaemon.enable` | `false` | Also run `leancli-agentd` (skills registry is wired to the packaged `share/leancli/skills` via `LEANCLI_SKILLS_DIR`). |
| `environment` | `{ }` | Extra env for both daemons; `~/.config/leancli/daemon.env` is still loaded on top per-user. |

## What the Nix package does NOT include

Anything that needs `npm install` at build time (the Nix sandbox has no
network):

- **Node sidecars** (`sidecars/kohaku`, `sidecars/clearsign`): the
  helios/colibri/safenode providers, the privacy plugins
  (railgun / privacy-pools / tornado), and ERC-7730 clearsigning. The
  daemon runs fine without them on the `rpc` provider — reads are then
  unverified (display-only anyway; the confirm gate, not simulation, is
  the trust anchor).
- **The Ink/React TUI** (`tui/`): the CLI surface is complete without it.
- The Rust `c9` SPHINCS+ shim (cargo fetch at build time); the two C
  parameter sets (`slhdsa`, `jardin`) are built and installed.

To use sidecars on NixOS, run them from a checkout inside the dev shell
and point the daemon at them.

## Hacking on leanCLI on NixOS

`/usr/lib/libcurl.so` and `/usr/lib/libsqlite3.so` (the lakefile's Linux
defaults) don't exist on NixOS, so the lakefile accepts overrides via
`-K` options. The dev shell exports ready-made values:

```bash
nix develop
lake "-KsysLibs=$LEANCLI_SYS_LIBS" "-KsysIncludes=$LEANCLI_SYS_INCLUDES" build
```

The shell ships the exact pinned Lean toolchain, cmake/ninja/cargo for
`lake script run setup-helpers`, and nodejs for the sidecars/TUI.

## Pinning notes

- The Lean toolchain comes from `lean4-nix.readToolchainFile
  ./lean-toolchain`. If a toolchain bump ever outruns lean4-nix's
  support, override the `lean` argument of `nix/package.nix` (any
  package putting matching `lean`/`lake`/`leanc` on PATH works, e.g.
  `pkgs.lean4` when its version matches).
- `hacl-packages` and `secp256k1` flake inputs are pinned to the same
  revisions as `ops/scripts/setup_hacl.sh` / `setup_secp256k1.sh`. Bump
  all three together.
- Plain `nix-build` (no flakes) works through `default.nix` but uses
  nixpkgs' `lean4` and eval-time `fetchGit` — flake use is the
  recommended path.
