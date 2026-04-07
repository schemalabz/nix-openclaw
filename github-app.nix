# GitHub App token management for the OpenClaw agent.
#
# When enabled, this module:
# - Generates GitHub App installation tokens (JWT + token exchange)
# - Refreshes them every 45 minutes via a systemd timer
# - Provides a `gh` CLI wrapper that reads the latest token on each invocation
# - Updates workspace .env files so containers get valid tokens
#
# No agent restarts needed — the gh wrapper reads from a token file.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.openclaw-agent;
  appCfg = cfg.githubApp;

  tokenFile = "/run/openclaw-github-token";

  tokenRefreshScript = pkgs.writeShellScript "openclaw-github-token-refresh" ''
    set -euo pipefail

    APP_ID="${appCfg.appId}"
    INSTALLATION_ID="${appCfg.installationId}"
    PEM_FILE="${appCfg.privateKeyFile}"

    if [ ! -f "$PEM_FILE" ]; then
      echo "FATAL: GitHub App private key not found at $PEM_FILE" >&2
      exit 1
    fi

    # --- Generate JWT (RS256, 10-minute expiry) ---
    b64url() { ${pkgs.openssl}/bin/openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

    NOW=$(date +%s)
    IAT=$((NOW - 60))
    EXP=$((NOW + 600))

    HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
    PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$IAT" "$EXP" "$APP_ID" | b64url)
    SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" \
      | ${pkgs.openssl}/bin/openssl dgst -sha256 -sign "$PEM_FILE" -binary | b64url)
    JWT="$HEADER.$PAYLOAD.$SIGNATURE"

    # --- Exchange JWT for installation access token ---
    RESPONSE=$(${pkgs.curl}/bin/curl -sf \
      -X POST \
      -H "Authorization: Bearer $JWT" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens")

    TOKEN=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.token')

    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
      echo "FATAL: Failed to obtain installation token" >&2
      echo "Response: $RESPONSE" >&2
      exit 1
    fi

    # --- Write token file (readable by agent) ---
    umask 077
    echo "$TOKEN" > "${tokenFile}"
    chown ${cfg.user}:${cfg.group} "${tokenFile}"
    echo "GitHub App token refreshed successfully"

    # --- Update workspace .env if dev-workspaces is enabled ---
    ${optionalString (config.services.dev-workspaces.enable or false) ''
      WS_ENV="${config.services.dev-workspaces.envFile}"
      if [ -f "$WS_ENV" ]; then
        ${pkgs.gnused}/bin/sed -i "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=$TOKEN|" "$WS_ENV"
        ${pkgs.gnused}/bin/sed -i "s|^GH_TOKEN=.*|GH_TOKEN=$TOKEN|" "$WS_ENV"
        # Add if not present
        grep -q '^GITHUB_TOKEN=' "$WS_ENV" || echo "GITHUB_TOKEN=$TOKEN" >> "$WS_ENV"
        grep -q '^GH_TOKEN=' "$WS_ENV" || echo "GH_TOKEN=$TOKEN" >> "$WS_ENV"
      fi
    ''}
  '';

  ghWrapper = pkgs.writeShellScriptBin "gh" ''
    if [ -f "${tokenFile}" ]; then
      export GH_TOKEN=$(cat "${tokenFile}")
    fi
    exec ${pkgs.gh}/bin/gh "$@"
  '';

in {
  options.services.openclaw-agent.githubApp = {
    enable = mkEnableOption "GitHub App token authentication (replaces static PAT)";

    appId = mkOption {
      type = types.str;
      default = "";
      description = "GitHub App ID (visible on the App's settings page).";
    };

    installationId = mkOption {
      type = types.str;
      default = "";
      description = "Installation ID (from the org/user installation URL after installing the App).";
    };

    privateKeyFile = mkOption {
      type = types.path;
      default = "/var/lib/openclaw-agent/github-app.pem";
      description = ''
        Path to the GitHub App private key PEM file.
        Generate from: GitHub App settings > Private keys > Generate a private key.
        Must be readable by the service user. Should be chmod 600.
      '';
    };

    _ghWrapper = mkOption {
      type = types.package;
      default = ghWrapper;
      internal = true;
      description = "The gh CLI wrapper package (internal, used by extraTools default).";
    };
  };

  config = mkIf (cfg.enable && appCfg.enable) {
    systemd.services.openclaw-github-token-refresh = {
      description = "Refresh GitHub App installation token";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = tokenRefreshScript;
      };
    };

    systemd.timers.openclaw-github-token-refresh = {
      description = "Refresh GitHub App token every 45 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "0min";
        OnUnitActiveSec = "45min";
        Persistent = true;
      };
    };
  };
}
