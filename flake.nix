{
  description = "NixOS module + deployment for OpenClaw agent gateway";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Upstream OpenClaw — provides the gateway binary.
    # Do NOT use follows for nixpkgs — their pin must match their binary cache.
    nix-openclaw.url = "github:openclaw/nix-openclaw";

    # Claude Code CLI for dev workspaces
    claude-code-nix.url = "github:sadjow/claude-code-nix";

    # Other services sharing this server
    opencouncil.url = "github:schemalabz/opencouncil/main";
    opencouncil-tasks.url = "github:schemalabz/opencouncil-tasks/main";
  };

  outputs = { self, nixpkgs, nix-openclaw, claude-code-nix, opencouncil, opencouncil-tasks }:
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

    # Re-export the gateway package for direct use
    packages.${system}.openclaw-gateway =
      nix-openclaw.packages.${system}.openclaw-gateway;

    # --- Host deployments ---
    nixosConfigurations.preview = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        { system.configurationRevision = self.rev or self.dirtyRev or "unknown"; }
        (nixpkgs + "/nixos/modules/virtualisation/digital-ocean-config.nix")
        (import ./generic-preview.nix opencouncil.preview)
        (import ./generic-preview.nix opencouncil-tasks.preview)
        self.nixosModules.default
        self.nixosModules.dev-workspaces
        ./hosts/preview/configuration.nix
      ];
    };

    # Evaluation check: catches type errors, missing options, broken references
    # without needing access to the server. Run: nix flake check
    checks.${system}.preview-module-eval = let
      eval = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          (import ./generic-preview.nix opencouncil.preview)
          (import ./generic-preview.nix opencouncil-tasks.preview)
          {
            services.opencouncil-preview.enable = true;
            services.opencouncil-tasks-preview = {
              enable = true;
              createUser = false;  # shared user created by opencouncil-preview
            };
            # Minimal config to satisfy NixOS module eval
            fileSystems."/" = { device = "/dev/sda1"; fsType = "ext4"; };
            boot.loader.grub.device = "/dev/sda";
          }
        ];
      };
    in eval.config.system.build.toplevel;

    # Formatter for `nix fmt`
    formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;
  };
}
