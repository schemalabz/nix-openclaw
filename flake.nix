{
  description = "NixOS module + deployment for OpenClaw agent gateway";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Web-access tools (page-read + playwright-run), shared with the team's
    # local Claude Code setup via the browser-scripting skill.
    toolkit.url = "github:schemalabz/toolkit/v2026.8.1";

    # Upstream OpenClaw — provides the gateway binary.
    # Do NOT use follows for nixpkgs — their pin must match their binary cache.
    nix-openclaw.url = "github:openclaw/nix-openclaw";

    # Claude Code CLI for dev workspaces
    claude-code-nix.url = "github:sadjow/claude-code-nix";

    # Other services sharing this server
    opencouncil.url = "github:schemalabz/opencouncil/main";
    opencouncil-tasks.url = "github:schemalabz/opencouncil-tasks/main";
  };

  outputs = { self, nixpkgs, toolkit, nix-openclaw, claude-code-nix, opencouncil, opencouncil-tasks }:
  let
    system = "x86_64-linux";
  in {
    # --- Reusable modules (importable by other flakes) ---
    nixosModules.default = import ./module.nix {
      inherit nix-openclaw;
      workspaceDir = ./workspace;
    };
    nixosModules.dev-workspaces = import ./workspace.nix {
      claude-code = claude-code-nix.packages.${system}.default;
    };
    nixosModules.noosphere = import ./noosphere.nix {
      vaultSeed = ./vault;
    };

    # Packages
    packages.${system} = let pkgs = nixpkgs.legacyPackages.${system}; in {
      # Re-export the gateway package for direct use
      openclaw-gateway = nix-openclaw.packages.${system}.openclaw-gateway;

      # Web-access tools — re-exported from schemalabz/toolkit, which is where
      # they now live. Consumers who want ONLY these should depend on toolkit
      # directly rather than on this flake.
      inherit (toolkit.packages.${system}) playwright-run page-read;

      # Noosphere CLI — initialize a vault anywhere
      # Usage: nix run .#noosphere-init -- <path>
      noosphere-init = pkgs.writeShellScriptBin "noosphere-init" ''
        set -euo pipefail

        VAULT="''${1:?Usage: noosphere-init <path>}"

        if [ ! -d "$VAULT/.git" ]; then
          echo "==> Initializing noosphere vault at $VAULT"
          mkdir -p "$VAULT"

          if [ -d "${./vault}" ]; then
            echo "==> Seeding vault"
            ${pkgs.rsync}/bin/rsync -a --ignore-existing --exclude='.git' "${./vault}/" "$VAULT/"
            chmod -R u+w "$VAULT"
          fi

          cd "$VAULT"
          ${pkgs.git}/bin/git init
          ${pkgs.git}/bin/git config user.name "Noosphere"
          ${pkgs.git}/bin/git config user.email "noosphere@localhost"
          ${pkgs.git}/bin/git add -A
          ${pkgs.git}/bin/git commit -m "vault: initial seed" --allow-empty
          echo "==> Vault initialized"
        else
          if [ -d "${./vault}" ]; then
            ${pkgs.rsync}/bin/rsync -a --ignore-existing --exclude='.git' "${./vault}/" "$VAULT/"
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
    };

    # --- Host deployments ---
    nixosConfigurations.preview = nixpkgs.lib.nixosSystem {
      inherit system;
      # Expose the flake's own packages (page-read, playwright-run, …) to the
      # host config so it can add them to the agent's tools.
      specialArgs = { inherit self; };
      modules = [
        { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
        (nixpkgs + "/nixos/modules/virtualisation/digital-ocean-config.nix")
        opencouncil.nixosModules.opencouncil-preview
        opencouncil-tasks.nixosModules.opencouncil-tasks-preview
        self.nixosModules.default
        self.nixosModules.dev-workspaces
        self.nixosModules.noosphere
        ./hosts/preview/configuration.nix
      ];
    };

    # Formatter for `nix fmt`
    formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;
  };
}
