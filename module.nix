# NixOS module for running OpenClaw gateway as a system-level service.
#
# This wraps the openclaw-gateway binary from nix-openclaw and manages:
# - Systemd service with security hardening
# - Workspace files (AGENTS.md, IDENTITY.md, SOUL.md, skills/, etc.)
# - openclaw.json config generation
# - docs/reference/templates/ workaround for nix-openclaw bug
# - Helper scripts for status, logs, restart
# - GitHub App token management (via github-app.nix sub-module)
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

  # session-read — standalone tool for reading OpenClaw session logs.
  # writeShellApplication wraps with proper bash from nixpkgs and adds
  # runtime dependencies to PATH.
  sessionRead = pkgs.writeShellApplication {
    name = "session-read";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    text = builtins.readFile ./scripts/session-read.sh;
  };

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
      # Token auth: the team authenticates with one shared token (OPENCLAW_GATEWAY_TOKEN
      # in the env file, not git). trustedProxies lets the gateway log the real client IP
      # behind Caddy (which reaches it over ::1/127.0.0.1) instead of the loopback address.
      # trusted-proxy auth can't be used here: Caddy is same-host, and the gateway refuses
      # to trust a loopback proxy source (trusted_proxy_loopback_source) — that needs the
      # proxy on a separate machine with its own IP.
      trustedProxies = [ "127.0.0.1" "::1" ];
    } // optionalAttrs (cfg.controlUiOrigins != [ ]) {
      # Browser origins allowed to reach the Control UI / WebChat over the WS API.
      # The gateway's default allowlist is bind-host only, so when the UI is served
      # through a reverse proxy on another host (nous.opencouncil.gr) it rejects the
      # proxied origin with WS close code 4008 ("connect failed") — this allows it.
      controlUi.allowedOrigins = cfg.controlUiOrigins;
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

    ${optionalString (cfg.envFile != null) ''
      if [ ! -f "${cfg.envFile}" ]; then
        echo "FATAL: envFile '${cfg.envFile}' does not exist." >&2
        echo "The service cannot start without its secrets." >&2
        echo "Create it with: DISCORD_BOT_TOKEN, ANTHROPIC_API_KEY, OPENCLAW_GATEWAY_TOKEN${optionalString (!cfg.githubApp.enable) ", GITHUB_TOKEN"}" >&2
        exit 1
      fi
    ''}

    DATA_DIR="${cfg.dataDir}"

    # Create directories
    mkdir -p "$DATA_DIR/state"
    mkdir -p "$DATA_DIR/.openclaw"
    mkdir -p "$DATA_DIR/workspace/skills"
    mkdir -p "$DATA_DIR/docs/reference/templates"

    # Copy workspace files from Nix store (not symlink — the gateway's
    # symlink-escape security check rejects symlinks resolving to /nix/store/).
    # Remove old symlinks first to avoid "same file" errors.
    for f in "${workspaceSrc}"/*.md; do
      name="$(basename "$f")"
      [ -L "$DATA_DIR/workspace/$name" ] && rm -f "$DATA_DIR/workspace/$name"
      cp -f "$f" "$DATA_DIR/workspace/$name"
    done

    # Copy skills into workspace (not symlink — the gateway's symlink-escape
    # security check rejects symlinks that resolve outside the workspace root,
    # which includes anything in /nix/store/)
    if [ -d "${workspaceSrc}/skills" ]; then
      for skill_dir in "${workspaceSrc}/skills"/*/; do
        if [ -d "$skill_dir" ]; then
          skill_name="$(basename "$skill_dir")"
          mkdir -p "$DATA_DIR/workspace/skills/$skill_name"
          for f in "$skill_dir"*; do
            if [ -f "$f" ]; then
              target="$DATA_DIR/workspace/skills/$skill_name/$(basename "$f")"
              [ -L "$target" ] && rm -f "$target"
              cp -f "$f" "$target"
            fi
          done
        fi
      done
    fi

    # Point .openclaw/workspace → workspace so the gateway reads Nix-managed files.
    # The gateway uses $HOME/.openclaw/workspace/ internally, regardless of
    # agents.defaults.workspace in openclaw.json.
    if [ -d "$DATA_DIR/.openclaw/workspace" ] && [ ! -L "$DATA_DIR/.openclaw/workspace" ]; then
      rm -rf "$DATA_DIR/.openclaw/workspace"
    fi
    ln -sfn "$DATA_DIR/workspace" "$DATA_DIR/.openclaw/workspace"

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

    # Ensure the service user owns everything — the setup script runs as
    # root (ExecStartPre=+) so files it creates would otherwise be root-owned.
    chown -R ${cfg.user}:${cfg.group} "$DATA_DIR"
  '';
in {
  imports = [ ./github-app.nix ];

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
        - OPENCLAW_GATEWAY_TOKEN
        - GITHUB_TOKEN / GH_TOKEN (only if githubApp is NOT enabled;
          when githubApp.enable = true, tokens are managed automatically)
        The file should be chmod 600, owned by the service user.
      '';
    };

    gatewayPort = mkOption {
      type = types.int;
      default = 8400;
      description = "Port for the OpenClaw gateway HTTP/WebSocket API (localhost only). Kept outside the 3000-4999 range used by opencouncil/tasks PR previews to avoid collisions.";
    };

    controlUiOrigins = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "https://nous.opencouncil.gr" ];
      description = "Extra browser origins allowed to reach the Control UI / WebChat WebSocket API. Set when the gateway UI is exposed through a reverse proxy on a different host; otherwise the gateway rejects the proxied origin (WS close code 4008).";
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
      default =
        (if cfg.githubApp.enable then [ cfg.githubApp._ghWrapper ] else [ pkgs.gh ])
        ++ [ sessionRead ];
      defaultText = literalExpression "[ pkgs.gh session-read ] (or gh wrapper when githubApp is enabled)";
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
      # Member of 'users' group (gid 100) so the agent can read/write
      # workspace container dirs (owned by dev:users inside containers).
      extraGroups = [ "users" ];
    };

    users.groups.${cfg.group} = mkIf (cfg.group == "openclaw") {};

    systemd.services.openclaw-agent = {
      description = "OpenClaw Agent Gateway";
      after = [ "network.target" ]
        ++ optional cfg.githubApp.enable "openclaw-github-token-refresh.service";
      wants = optionals cfg.githubApp.enable [ "openclaw-github-token-refresh.service" ];
      wantedBy = [ "multi-user.target" ];
      path = cfg.extraTools ++ [ "/run/current-system/sw" ];

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
        # Auth mode (password) comes from gateway.auth in the config file, not a flag.
        ExecStart = "${openclaw-gateway}/bin/openclaw gateway --port ${toString cfg.gatewayPort}";
        Restart = "on-failure";
        RestartSec = "5s";

        # Security hardening
        # Disabled when dev-workspaces is enabled — workspace scripts need
        # sudo to manage NixOS containers, which requires privilege escalation.
        NoNewPrivileges = !(config.services.dev-workspaces.enable or false);
        PrivateTmp = true;
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    # Helper scripts + gh wrapper (must be in systemPackages so it lands in
    # /run/current-system/sw/bin, which the agent's spawned shells can find)
    environment.systemPackages = cfg.extraTools ++ [
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
