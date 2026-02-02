# Example droplet /etc/nixos/configuration.nix using the nix-openclaw module.
#
# Pair with a /etc/nixos/flake.nix that imports the module:
#
#   {
#     inputs = {
#       nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
#       nix-openclaw.url = "github:schemalabz/nix-openclaw";
#     };
#
#     outputs = { self, nixpkgs, nix-openclaw, ... }: {
#       nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
#         system = "x86_64-linux";
#         modules = [
#           nix-openclaw.nixosModules.default
#           ./configuration.nix
#         ];
#       };
#     };
#   }

{ ... }:

{
  services.openclaw-agent = {
    enable = true;
    envFile = "/var/lib/openclaw-agent/.env";

    # Optional: restrict to specific guilds/channels
    # discord.guilds = {
    #   "YOUR_GUILD_ID" = {
    #     requireMention = true;
    #     channels = [ "CHANNEL_ID" ];
    #   };
    # };

    # Optional: tune concurrency
    # maxConcurrent = 4;
    # maxConcurrentSubagents = 8;

    # Optional: extra config merged into openclaw.json
    # extraConfig = {
    #   heartbeat = { intervalMinutes = 60; };
    # };
  };
}
