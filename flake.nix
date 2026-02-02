{
  description = "NixOS module for running OpenClaw agent gateway as a systemd service";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nix-openclaw.url = "github:openclaw/nix-openclaw";
    # Do NOT use `follows = "nixpkgs"` here — nix-openclaw pins its own nixpkgs
    # to ensure the gateway binary matches their binary cache. Overriding it
    # forces a from-source rebuild (~1.2GB CUDA deps) that OOM-kills small VPS.
  };

  outputs = { self, nixpkgs, nix-openclaw }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      nixosModules.default = import ./module.nix {
        inherit nix-openclaw;
        workspaceDir = ./workspace;
      };

      # Re-export the gateway package for direct use
      packages.${system}.openclaw-gateway =
        nix-openclaw.packages.${system}.openclaw-gateway;
    };
}
