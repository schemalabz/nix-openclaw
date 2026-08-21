# Host config for the preview server (159.89.98.26, DigitalOcean).
#
# Service modules (opencouncil-preview, opencouncil-tasks-preview,
# openclaw-agent) are imported from the flake — this file only holds
# host-level settings and per-service knobs.

{ lib, pkgs, self, opencouncil, opencouncil-tasks, ... }:

let
  healthPort = 9101;
in
{
  networking.hostName = "opencouncil-preview";

  # PR previews for both projects via the generic pr-previews module.
  # Project definitions (start scripts, hooks, DB lifecycle) live in the app
  # flakes' `previews` exports; this block only pins host-level knobs.
  # user/group/dirs deliberately match the pre-extraction setup so existing
  # preview instances and per-PR DB clusters keep working.
  services.pr-previews = {
    enable = true;
    user = "opencouncil";
    group = "opencouncil";
    # Continuity: the CI deploy key lives in this home's .ssh/authorized_keys
    # (sshd resolves it relative to the user's home).
    homeDir = "/var/lib/opencouncil-previews";
    projects = {
      opencouncil = lib.mkMerge [
        opencouncil.previews.opencouncil
        {
          envFile = "/var/lib/opencouncil-previews/.env";
          settings.tasksPreview = {
            domain = "tasks.opencouncil.dev";
            envFile = "/var/lib/opencouncil-tasks-previews/.env";
          };
        }
      ];
      opencouncil-tasks = lib.mkMerge [
        opencouncil-tasks.previews.opencouncil-tasks
        { envFile = "/var/lib/opencouncil-tasks-previews/.env"; }
      ];
    };
  };

  # Ephemeral dev workspaces (NixOS containers)
  services.dev-workspaces = {
    enable = true;
    slots = 4;
    user = "openclaw";
    group = "openclaw";
  };

  networking.nat.externalInterface = "ens3";

  # Noosphere — shared knowledge vault for agents
  services.noosphere = {
    enable = true;
    user = "openclaw";
    group = "openclaw";
  };

  # OpenClaw agent (Discord bot + future capabilities)
  services.openclaw-agent = {
    enable = true;
    dataDir = "/var/lib/opencouncil-discord-bot";
    envFile = "/var/lib/opencouncil-discord-bot/.env";
    # Web-access CLIs for the agent (see the browser-scripting skill): read a
    # page as clean markdown (page-read) or drive a real browser (playwright-run).
    extraTools = [
      self.packages.${pkgs.system}.page-read
      self.packages.${pkgs.system}.playwright-run
    ];
    # The Control UI is served through Caddy at this origin; allow it past the
    # gateway's CSRF origin check (default allowlist is bind-host/localhost only).
    controlUiOrigins = [ "https://nous.opencouncil.gr" ];
    # Disable heartbeats to save tokens when idle
    extraConfig = {
      agents.defaults = {
        model = "anthropic/claude-sonnet-4-6";
        heartbeat.every = "0m";
      };
    };
    # GitHub App for repository access (auto-refreshing tokens, no PAT needed)
    githubApp = {
      enable = true;
      appId = "3304452";
      installationId = "122106827";
      privateKeyFile = "/var/lib/opencouncil-discord-bot/github-app.pem";
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

  # Trust the garnix binary cache used by nix-openclaw.
  # Without this, the server tries to build openclaw-gateway from source
  # and OOMs on the CUDA/llama-cpp npm deps (~500MB downloads).
  nix.settings = {
    extra-substituters = [ "https://cache.garnix.io" ];
    extra-trusted-public-keys = [ "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=" ];
  };

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

  # Expose the OpenClaw gateway to the team. Caddy terminates TLS and reverse-proxies to
  # the loopback gateway; the gateway authenticates with one shared token
  # (OPENCLAW_GATEWAY_TOKEN in the env file). Team members open a pre-tokenized URL
  # (https://nous.opencouncil.gr/?token=...) so they never touch the connect dialog.
  services.caddy.virtualHosts."nous.opencouncil.gr".extraConfig = ''
    reverse_proxy localhost:8400 {
      header_up Host {host}
      header_up X-Real-IP {remote_host}
      header_up X-Forwarded-For {remote_host}
      header_up X-Forwarded-Proto {scheme}
    }
  '';

  system.stateVersion = "24.11";
}
