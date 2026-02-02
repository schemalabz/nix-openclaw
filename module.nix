# NixOS module for running OpenClaw gateway as a system-level service.
#
# This wraps the openclaw-gateway binary from nix-openclaw and manages:
# - Systemd service with security hardening
# - Workspace files (AGENTS.md, IDENTITY.md, SOUL.md, skills/, etc.)
# - openclaw.json config generation
# - docs/reference/templates/ workaround for nix-openclaw bug
# - Helper scripts for status, logs, restart
#
# Runtime-mutable state (sessions, device identity, cron) lives in dataDir
# and is NOT managed by Nix. Workspace files are read-only symlinks from
# the Nix store.

{ nix-openclaw, workspaceDir }:

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.openclaw-agent;
  defaultGateway = nix-openclaw.packages.${pkgs.system}.openclaw-gateway;
  openclaw-gateway = cfg.package;

  # Workspace files tracked in this repo (read-only, symlinked into dataDir)
  workspaceSrc = workspaceDir;

  # Generate openclaw.json from Nix attrset.
  # Runtime-mutable fields (wizard.*, meta.*) are NOT included here —
  # the ExecStartPre script merges them from the existing file on disk.
  openclawConfig = {
    agents = {
      defaults = {
        workspace = "${cfg.dataDir}/workspace";
        maxConcurrent = cfg.maxConcurrent;
        subagents = {
          maxConcurrent = cfg.maxConcurrentSubagents;
        };
      };
    };
    commands = {
      native = "auto";
      nativeSkills = "auto";
    };
    channels = {
      discord = {
        enabled = cfg.discord.enable;
        guilds = cfg.discord.guilds;
      };
    };
    gateway = {
      port = cfg.gatewayPort;
      mode = "local";
    };
    messages = {
      ackReactionScope = "group-mentions";
    };
    plugins = {
      entries = {
        discord = {
          enabled = cfg.discord.enable;
        };
      };
    };
  } // cfg.extraConfig;

  openclawConfigJSON = pkgs.writeText "openclaw.json"
    (builtins.toJSON openclawConfig);

  # Script that sets up the workspace and config before the gateway starts
  setupScript = pkgs.writeShellScript "openclaw-agent-setup" ''
    set -euo pipefail

    DATA_DIR="${cfg.dataDir}"

    # Create directories
    mkdir -p "$DATA_DIR/state"
    mkdir -p "$DATA_DIR/.openclaw"
    mkdir -p "$DATA_DIR/workspace/skills"
    mkdir -p "$DATA_DIR/docs/reference/templates"

    # Symlink read-only workspace files from Nix store.
    # These are the files the gateway reads but does not modify.
    for f in "${workspaceSrc}"/*.md; do
      name="$(basename "$f")"
      ln -sfn "$f" "$DATA_DIR/workspace/$name"
    done

    # Symlink skills directories
    if [ -d "${workspaceSrc}/skills" ]; then
      for skill_dir in "${workspaceSrc}/skills"/*/; do
        if [ -d "$skill_dir" ]; then
          skill_name="$(basename "$skill_dir")"
          mkdir -p "$DATA_DIR/workspace/skills/$skill_name"
          for f in "$skill_dir"*; do
            [ -f "$f" ] && ln -sfn "$f" "$DATA_DIR/workspace/skills/$skill_name/$(basename "$f")"
          done
        fi
      done
    fi

    # Copy workspace files into docs/reference/templates/ as a workaround
    # for the nix-openclaw bug where the gateway package is missing these.
    # See: https://gist.github.com/gudnuf/8fe65ca0e49087105cb86543dc8f0799
    for f in "$DATA_DIR/workspace"/*.md; do
      name="$(basename "$f")"
      # Resolve symlink and copy the actual file
      cp -fL "$f" "$DATA_DIR/docs/reference/templates/$name"
    done

    # Generate openclaw.json, preserving runtime-mutable fields from
    # any existing config (wizard.*, meta.*, .openclaw/identity/).
    if [ -f "$DATA_DIR/openclaw.json" ]; then
      # Merge: Nix-managed fields overwrite, but keep wizard/meta from existing
      ${pkgs.jq}/bin/jq -s '
        # $existing is .[0], $new is .[1]
        .[0] as $existing | .[1] as $new |
        $new + {
          wizard: ($existing.wizard // {}),
          meta: ($existing.meta // {})
        }
      ' "$DATA_DIR/openclaw.json" "${openclawConfigJSON}" > "$DATA_DIR/openclaw.json.tmp"
      mv "$DATA_DIR/openclaw.json.tmp" "$DATA_DIR/openclaw.json"
    else
      cp "${openclawConfigJSON}" "$DATA_DIR/openclaw.json"
    fi
    chmod 600 "$DATA_DIR/openclaw.json"
  '';
in {
  options.services.openclaw-agent = {
    enable = mkEnableOption "OpenClaw agent gateway";

    package = mkOption {
      type = types.package;
      default = defaultGateway;
      description = ''
        The openclaw-gateway package to use. Override this if the default
        (from nix-openclaw flake) triggers a from-source build due to
        nixpkgs version mismatch.
      '';
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/openclaw-agent";
      description = ''
        Directory for OpenClaw runtime state (sessions, device identity, config).
        Workspace files are symlinked here from the Nix store.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "openclaw";
      description = "User to run the gateway service.";
    };

    group = mkOption {
      type = types.str;
      default = "openclaw";
      description = "Group to run the gateway service.";
    };

    envFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to environment file with secrets. Expected variables:
        - DISCORD_BOT_TOKEN
        - ANTHROPIC_API_KEY
        - GITHUB_TOKEN (or GH_TOKEN)
        - OPENCLAW_GATEWAY_TOKEN
        The file should be chmod 600, owned by the service user.
      '';
    };

    gatewayPort = mkOption {
      type = types.int;
      default = 3400;
      description = "Port for the OpenClaw gateway HTTP/WebSocket API (localhost only).";
    };

    maxConcurrent = mkOption {
      type = types.int;
      default = 4;
      description = "Maximum concurrent agent runs.";
    };

    maxConcurrentSubagents = mkOption {
      type = types.int;
      default = 8;
      description = "Maximum concurrent subagent runs.";
    };

    extraTools = mkOption {
      type = types.listOf types.package;
      default = [ pkgs.gh ];
      description = "Extra packages to add to the gateway's PATH (e.g., gh, git).";
    };

    discord = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable the Discord channel.";
      };

      guilds = mkOption {
        type = types.attrs;
        default = {
          "*" = {
            requireMention = true;
          };
        };
        description = ''
          Discord guild configuration. Keys are guild IDs (or "*" for all guilds).
          See https://docs.openclaw.ai/channels/discord for options.
        '';
      };
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = {};
      description = ''
        Extra attrset merged into openclaw.json at the top level.
        Use this for provider overrides, heartbeat config, etc.
      '';
    };
  };

  config = mkIf cfg.enable {
    users.users.${cfg.user} = mkIf (cfg.user == "openclaw") {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      shell = pkgs.bash;
    };

    users.groups.${cfg.group} = mkIf (cfg.group == "openclaw") {};

    systemd.services.openclaw-agent = {
      description = "OpenClaw Agent Gateway";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      path = cfg.extraTools;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        EnvironmentFile = mkIf (cfg.envFile != null) cfg.envFile;
        Environment = [
          "OPENCLAW_NIX_MODE=1"
          "OPENCLAW_CONFIG_PATH=${cfg.dataDir}/openclaw.json"
          "OPENCLAW_STATE_DIR=${cfg.dataDir}/state"
          "HOME=${cfg.dataDir}"
        ];
        WorkingDirectory = cfg.dataDir;
        ExecStartPre = "+${setupScript}";
        ExecStart = "${openclaw-gateway}/bin/openclaw gateway --port ${toString cfg.gatewayPort}";
        Restart = "on-failure";
        RestartSec = "5s";

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    # Helper scripts
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "openclaw-agent-status" ''
        exec systemctl status openclaw-agent "$@"
      '')
      (pkgs.writeShellScriptBin "openclaw-agent-logs" ''
        if [ $# -eq 0 ]; then
          exec journalctl -u openclaw-agent -f
        else
          exec journalctl -u openclaw-agent "$@"
        fi
      '')
      (pkgs.writeShellScriptBin "openclaw-agent-restart" ''
        exec sudo systemctl restart openclaw-agent
      '')
    ];

    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "${pkgs.systemd}/bin/systemctl restart openclaw-agent";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
