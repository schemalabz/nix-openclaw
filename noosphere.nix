# NixOS module for the Noosphere — a shared Obsidian-compatible knowledge vault.
#
# Manages:
# - Vault directory initialization and seeding
# - Git repository for version history and backups
# - Periodic auto-commit timer for backup
#
# The vault is a shared resource: multiple agents read from and write to it.
# Humans can open it in Obsidian on their devices and sync via git.
#
# See NOOSPHERE.md in the vault seed for the protocol specification.

{ vaultSeed }:

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.noosphere;

  # Core init logic — used by both the systemd service and the standalone CLI
  initVault = pkgs.writeShellScriptBin "noosphere-init" ''
    set -euo pipefail

    VAULT="''${1:-${cfg.vaultDir}}"

    # First-time initialization
    if [ ! -d "$VAULT/.git" ]; then
      echo "==> Initializing noosphere vault at $VAULT"
      mkdir -p "$VAULT"

      # Seed with initial content from Nix store
      if [ -d "${vaultSeed}" ]; then
        echo "==> Seeding vault from ${vaultSeed}"
        ${pkgs.rsync}/bin/rsync -a --ignore-existing "${vaultSeed}/" "$VAULT/"
      fi

      # Initialize git repo
      cd "$VAULT"
      ${pkgs.git}/bin/git init
      ${pkgs.git}/bin/git config user.name "Noosphere"
      ${pkgs.git}/bin/git config user.email "noosphere@localhost"
      ${pkgs.git}/bin/git add -A
      ${pkgs.git}/bin/git commit -m "vault: initial seed" --allow-empty
      echo "==> Vault initialized at $VAULT"
    else
      # On subsequent deploys, seed new files without overwriting existing ones
      if [ -d "${vaultSeed}" ]; then
        ${pkgs.rsync}/bin/rsync -a --ignore-existing "${vaultSeed}/" "$VAULT/"
      fi
      echo "==> Vault already initialized at $VAULT"
    fi

    echo ""
    echo "==> Contents:"
    find "$VAULT" -type f -not -path '*/.git/*' | sort | sed 's|^|    |'
    echo ""
    echo "==> Git log:"
    cd "$VAULT" && ${pkgs.git}/bin/git log --oneline | sed 's|^|    |'
  '';

  # Backup script — auto-commit vault changes
  backupVault = pkgs.writeShellScriptBin "noosphere-backup" ''
    set -euo pipefail

    VAULT="''${1:-${cfg.vaultDir}}"
    cd "$VAULT"

    ${pkgs.git}/bin/git add -A

    if ! ${pkgs.git}/bin/git diff --cached --quiet; then
      ${pkgs.git}/bin/git commit -m "vault: auto-backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "==> Vault backup committed"
    else
      echo "==> No changes to backup"
    fi
  '';
in {
  options.services.noosphere = {
    enable = mkEnableOption "Noosphere knowledge vault";

    vaultDir = mkOption {
      type = types.path;
      default = "/var/lib/noosphere/vault";
      description = ''
        Path to the Obsidian-compatible vault directory.
        This is the shared knowledge base that agents read from and write to.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "openclaw";
      description = "User that owns the vault.";
    };

    group = mkOption {
      type = types.str;
      default = "openclaw";
      description = "Group that owns the vault.";
    };

    backup = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable periodic git auto-commit for vault backup.";
      };

      interval = mkOption {
        type = types.str;
        default = "hourly";
        description = "Systemd calendar expression for backup frequency.";
      };
    };
  };

  config = mkIf cfg.enable {
    # Ensure vault directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.vaultDir} 0755 ${cfg.user} ${cfg.group} -"
    ];

    # Initialize vault on boot (before agents start)
    systemd.services.noosphere-init = {
      description = "Initialize Noosphere knowledge vault";
      after = [ "local-fs.target" ];
      before = [ "openclaw-agent.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "+${initVault}/bin/noosphere-init";
      };
    };

    # Periodic backup via git commit
    systemd.services.noosphere-backup = mkIf cfg.backup.enable {
      description = "Backup Noosphere vault (git commit)";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${backupVault}/bin/noosphere-backup";
      };
    };

    systemd.timers.noosphere-backup = mkIf cfg.backup.enable {
      description = "Periodic Noosphere vault backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.backup.interval;
        Persistent = true;
      };
    };

    # Make init and backup scripts available on the server
    environment.systemPackages = [ initVault backupVault ];
  };
}
