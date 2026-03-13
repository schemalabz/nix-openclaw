"""Tiny health endpoint for the preview server.

Serves GET /health with JSON: deployed revision, NixOS version,
and live systemd service statuses.

Port is passed as the first CLI argument.
"""

import http.server
import json
import subprocess
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            return

        services = {}
        healthy = True

        # Single services — detect crash-looping via ActiveState+SubState
        for svc in ["openclaw-agent"]:
            r = subprocess.run(
                ["systemctl", "show", svc,
                 "--property=ActiveState,SubState"],
                capture_output=True, text=True,
            )
            props = dict(
                line.split("=", 1)
                for line in r.stdout.strip().splitlines()
                if "=" in line
            )
            active = props.get("ActiveState", "unknown")
            sub = props.get("SubState", "unknown")

            if active == "active" and sub == "running":
                services[svc] = "active"
            elif active == "activating" and sub == "auto-restart":
                services[svc] = "crash-looping"
                healthy = False
            else:
                services[svc] = f"{active}/{sub}"
                healthy = False

        # Workspace containers — count active instances
        r = subprocess.run(
            ["systemctl", "list-units", "--type=service",
             "--state=active", "--no-pager", "--no-legend",
             "container@workspace-*"],
            capture_output=True, text=True,
        )
        lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
        services["dev-workspaces"] = len(lines)

        # Templated services — count active instances
        for prefix in ["opencouncil-preview", "opencouncil-tasks-preview"]:
            r = subprocess.run(
                ["systemctl", "list-units", "--type=service",
                 "--state=active", "--no-pager", "--no-legend",
                 f"{prefix}@*"],
                capture_output=True, text=True,
            )
            lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
            services[prefix] = len(lines)

        # NixOS version info — use full path since DynamicUser has limited PATH
        try:
            r = subprocess.run(
                ["/run/current-system/sw/bin/nixos-version", "--json"],
                capture_output=True, text=True,
            )
            ver = json.loads(r.stdout)
        except Exception:
            ver = {}

        body = json.dumps({
            "ok": healthy,
            "revision": ver.get("configurationRevision", "unknown"),
            "nixos_version": ver.get("nixosVersion", "unknown"),
            "services": services,
        }, indent=2)

        self.send_response(200 if healthy else 503)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9101
    http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
