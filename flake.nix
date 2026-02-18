{
  description = "NixOS module + deployment for OpenClaw agent gateway";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    # Upstream OpenClaw — provides the gateway binary.
    # Do NOT use follows for nixpkgs — their pin must match their binary cache.
    nix-openclaw.url = "github:openclaw/nix-openclaw";

    # Other services sharing this server
    opencouncil.url = "github:schemalabz/opencouncil/main";
    opencouncil-tasks.url = "github:schemalabz/opencouncil-tasks/main";
  };

  outputs = { self, nixpkgs, nix-openclaw, opencouncil, opencouncil-tasks }:
  let
    system = "x86_64-linux";
  in {
    # --- Reusable module (importable by other flakes) ---
    nixosModules.default = import ./module.nix {
      inherit nix-openclaw;
      workspaceDir = ./workspace;
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
        opencouncil.nixosModules.opencouncil-preview
        opencouncil-tasks.nixosModules.opencouncil-tasks-preview
        self.nixosModules.default
        ./hosts/preview/configuration.nix
      ];
    };

    # Formatter for `nix fmt`
    formatter.${system} = nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;
  };
}
