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

        # Single services
        for svc in ["openclaw-agent"]:
            r = subprocess.run(
                ["systemctl", "is-active", svc],
                capture_output=True, text=True,
            )
            services[svc] = r.stdout.strip()

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
            "revision": ver.get("configurationRevision", "unknown"),
            "nixos_version": ver.get("nixosVersion", "unknown"),
            "services": services,
        }, indent=2)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9101
    http.server.HTTPServer(("0.0.0.0", port), Handler).serve_forever()
