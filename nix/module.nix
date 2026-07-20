# NixOS module for leanCLI. Imported through the flake:
#
#   imports = [ inputs.leancli.nixosModules.default ];
#   services.leancli.enable = true;
#
# The wallet daemon and agent daemon are per-user services (they listen
# on $XDG_RUNTIME_DIR/leancli/*.sock and keep wallet state under $HOME),
# so this module defines systemd *user* units, mirroring
# ops/packaging/systemd/*.service with store-path ExecStarts.
#
# The outer `self:` is the leanCLI flake itself, bound in flake.nix —
# it provides the default package for the target system.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.leancli;
in
{
  options.services.leancli = {
    enable = lib.mkEnableOption
      "leanCLI, the formally modeled Ethereum wallet (CLI + per-user wallet daemon)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "leancli.packages.\${system}.default";
      description = "leanCLI package to run.";
    };

    provider = lib.mkOption {
      type = lib.types.str;
      default = "rpc";
      example = "helios";
      description = ''
        Read backend for chain reads and simulation (LEANCLI_PROVIDER).
        The Nix package ships the Lean core only — the helios/colibri
        Node sidecars are not packaged — so the default here is "rpc"
        (direct configured RPC endpoint, no light-client verification),
        not the upstream default "helios". Point a checkout's sidecars
        at the daemon and flip this if you need consensus-verified
        reads.
      '';
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start the daemon(s) at user login (WantedBy=default.target).
        Upstream ships manual-lifecycle units; set false to match that
        and start with `systemctl --user start leancli-daemon` instead.
      '';
    };

    agentDaemon.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Also run leancli-agentd, the persistent LLM agent daemon
        (SQLite-backed sessions on $XDG_RUNTIME_DIR/leancli/agent.sock).
        Needs an OpenAI-compatible endpoint configured to be useful.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression
        ''{ LEANCLI_PRIVACY = "tornado"; }'';
      description = ''
        Extra environment for both daemons (RPC endpoints, plugin
        allow-lists, …). Per-user overrides still work via
        ~/.config/leancli/daemon.env, which the unit loads on top.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.user.services.leancli-daemon = {
      description = "leanCLI wallet daemon";
      after = [ "default.target" ];
      wantedBy = lib.optional cfg.autoStart "default.target";
      environment = { LEANCLI_PROVIDER = cfg.provider; } // cfg.environment;
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/leancli-daemon";
        # daemon.env is auxiliary — daemon.json under $XDG_CONFIG_HOME
        # stays authoritative; `-` tolerates a fresh install without it.
        EnvironmentFile = "-%h/.config/leancli/daemon.env";
        Restart = "on-failure";
        RestartSec = 2;
        KillMode = "control-group";
        TimeoutStopSec = 10;
        # Hardening kept in lockstep with
        # ops/packaging/systemd/leancli-daemon.service (conservative: a
        # wallet reading config and writing state under $HOME).
        NoNewPrivileges = true;
        PrivateTmp = true;
        LockPersonality = true;
        RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
      };
    };

    systemd.user.services.leancli-agentd = lib.mkIf cfg.agentDaemon.enable {
      description = "leanCLI agent daemon (LLM sessions)";
      after = [ "leancli-daemon.service" ];
      wantedBy = lib.optional cfg.autoStart "default.target";
      environment = {
        # The store install has no <cwd>/skills; point the registry at
        # the packaged tree.
        LEANCLI_SKILLS_DIR = "${cfg.package}/share/leancli/skills";
      } // cfg.environment;
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/leancli-agentd";
        EnvironmentFile = "-%h/.config/leancli/daemon.env";
        Restart = "on-failure";
        RestartSec = 2;
        NoNewPrivileges = true;
        PrivateTmp = true;
        LockPersonality = true;
        RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
      };
    };
  };
}
