# Host config for the preview server (159.89.98.26, DigitalOcean).
#
# Service modules (opencouncil-preview, opencouncil-tasks-preview,
# openclaw-agent) are imported from the flake — this file only holds
# host-level settings and per-service knobs.

{ pkgs, ... }:

let
  healthPort = 9101;
in
{
  networking.hostName = "opencouncil-preview";

  services.opencouncil-preview = {
    enable = true;
    basePort = 3000;
    envFile = "/var/lib/opencouncil-previews/.env";
    cachix.enable = true;
  };

  # OpenCouncil Tasks API previews (port 4000+N)
  services.opencouncil-tasks-preview = {
    enable = true;
    basePort = 4000;
    envFile = "/var/lib/opencouncil-tasks-previews/.env";
    previewDomain = "tasks.opencouncil.gr";
    cachix.enable = true;
  };

  # OpenClaw agent (Discord bot + future capabilities)
  services.openclaw-agent = {
    enable = true;
    dataDir = "/var/lib/opencouncil-discord-bot";
    envFile = "/var/lib/opencouncil-discord-bot/.env";
    user = "root";
    group = "root";
    # Disable heartbeats to save tokens when idle
    extraConfig = {
      agents.defaults.heartbeat.every = "0m";
    };
  };

  # Health check endpoint — GET http://<ip>:9101/health
  systemd.services.health = {
    description = "Health check HTTP endpoint";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${./health-server.py} ${toString healthPort}";
      Restart = "always";
      RestartSec = "5s";
      DynamicUser = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ healthPort ];

  # 4GB swap file — the VPS only has 3.8GB RAM, and from-source builds of
  # openclaw-gateway (CUDA deps) need more. This lets `nix flake update`
  # work without worrying about binary cache timing.
  swapDevices = [{ device = "/swapfile"; size = 4096; }];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2N1Ic/eIVKjHH48Tocg/+6bwpKgj2a+HnqMBMsRDEr kouloumos@kouloumos"
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDiDna9WPo7ZvY4L21uUjAzqVr32nxr4gC1fUrfUosKkfqSDLEjKYiWt7rMcunXKs+iLjfDnPDN4+rncehve5cxdpLRjchKSj8RwT19nFpByrl/r/0zu3xvHnRqieTeHqxySv1rvZifnoRv4UGm1IU4ndqgU0gp5FuTQ0UdAlF7PM1cFzK1EjEf4T1l5qNEs0qx5LtCI6y9UwqDY4eUk//ipTF9SaKdi6l5SEcZrVxnwC4uwDTq57awxcZUNHazTxcRlXPSQ0Hk4oHpX0UXbQY3vZuVC7w0uRJ3BtvUoAVaLmH9svbTFnqujaQjsjCBt/W93S6m7H08D/FnvsjZDj1UmtKsZleIqWcF8OxnCX7MWaZN+f1XHNubRYXr4bC/G8+ZC+aRN7T26mXRYjjABUVic2xrOT34U6tnS1plM4UIgzHI3lgjuB2yAwQs11oNbCLo0gH1rLGtB0kesnq0Zdws0COSKuLlLW9Q0dYuxJN93YK+i/AVrTpCcJyWhxeaKPs= christos@Christoss-MacBook-Pro.local"
  ];

  system.stateVersion = "24.11";
}
