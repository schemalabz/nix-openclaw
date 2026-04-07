# nix-openclaw

NixOS-based development platform that combines PR preview deployments, AI agent orchestration, and ephemeral dev workspaces on a single server. Built for the [Schema Labs](https://github.com/schemalabz) / [OpenCouncil](https://github.com/schemalabz/opencouncil) project.

- **PR Preview Deployments** — Automatic per-PR preview environments with Caddy reverse proxy and wildcard TLS (`pr-N.preview.opencouncil.gr`, `pr-N.tasks.opencouncil.gr`). GitHub Actions builds, Cachix caches, and the server deploys each PR as an isolated service instance.
- **OpenClaw Agent** — Discord bot gateway as a systemd service, with workspace files (identity, skills) managed via Nix and symlinked read-only
- **Dev Workspaces** — Ephemeral NixOS containers (systemd-nspawn) with full dev toolchains, headless Claude Code agents, and SSH access
- **Agent Orchestration Skills** — Skills that teach the bot to plan tasks, execute implementation plans, and create PRs — all through the workspace containers

## Prerequisites

- A NixOS machine (tested on 24.11)
- Discord bot token ([Developer Portal](https://discord.com/developers/applications))
- Anthropic API key
- GitHub App (for `gh` CLI in agent skills — see [GitHub App setup](#3-set-up-github-app-for-repository-access))

## Setup

### 1. Add to your flake

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nix-openclaw.url = "github:schemalabz/nix-openclaw";
  };

  outputs = { nixpkgs, nix-openclaw, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nix-openclaw.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
{
  services.openclaw-agent = {
    enable = true;
    envFile = "/var/lib/openclaw-agent/.env";

    # Optional overrides (defaults shown)
    # gatewayPort = 3400;
    # maxConcurrent = 4;
    # discord.guilds."*".requireMention = true;
  };
}
```

### 2. Create the Discord bot

1. Create application at https://discord.com/developers/applications
2. **Bot** tab: copy token, enable **Message Content Intent** and **Server Members Intent**
3. **OAuth2** → URL Generator: scopes `bot` + `applications.commands`
4. Permissions: Send Messages, Send Messages in Threads, Create Public Threads, Add Reactions, Read Message History, Embed Links
5. Invite the bot to your server with the generated URL

### 3. Set up GitHub App for repository access

The agent uses a GitHub App (not a personal token) so it has its own identity and doesn't depend on any individual's account. Installation tokens are refreshed automatically every 45 minutes.

#### Create the App

1. Go to **Settings → Developer settings → GitHub Apps → New GitHub App**
2. Fill in:
   - **Name**: e.g. "OpenCouncil Bot" (must be globally unique)
   - **Homepage URL**: your project URL (required field, anything works)
   - **Webhook**: uncheck "Active" (not needed)
3. Set **Repository permissions**:
   - **Contents**: Read
   - **Issues**: Read and Write
   - **Pull requests**: Read and Write
   - **Metadata**: Read (automatically selected)
4. Under "Where can this GitHub App be installed?", select **Only on this account**
5. Click **Create GitHub App**
6. Note the **App ID** shown on the settings page

#### Generate a private key

1. On the App settings page, scroll to **Private keys**
2. Click **Generate a private key** — a `.pem` file downloads
3. Deploy it to the server:
   ```bash
   scp your-app.pem root@<server>:/var/lib/openclaw-agent/github-app.pem
   ssh root@<server> "chmod 600 /var/lib/openclaw-agent/github-app.pem"
   ```

#### Install the App on your org/repos

1. Go to the App's page → **Install App**
2. Select your org and choose which repos to grant access to
3. After installing, note the **Installation ID** from the URL:
   `https://github.com/settings/installations/<INSTALLATION_ID>`

#### Configure the NixOS module

```nix
services.openclaw-agent = {
  # ...
  githubApp = {
    enable = true;
    appId = "<your App ID>";
    installationId = "<your Installation ID>";
    privateKeyFile = "/var/lib/openclaw-agent/github-app.pem";
  };
};
```

When `githubApp` is enabled:
- A systemd timer refreshes the token every 45 minutes
- The `gh` CLI wrapper reads the latest token on each invocation (no service restarts)
- Workspace containers get fresh tokens automatically at creation time

### 4. Create the secrets file on the server

```bash
mkdir -p /var/lib/openclaw-agent
cat > /var/lib/openclaw-agent/.env << 'EOF'
DISCORD_BOT_TOKEN=your_discord_bot_token
ANTHROPIC_API_KEY=your_anthropic_api_key
OPENCLAW_GATEWAY_TOKEN=any_random_uuid
EOF
chmod 600 /var/lib/openclaw-agent/.env
```

> **Note:** `GITHUB_TOKEN` / `GH_TOKEN` are not needed in the secrets file when `githubApp` is enabled — they are managed automatically by the token refresh timer.

### 5. Deploy

```bash
nixos-rebuild switch --flake .#myhost
```

### 6. Verify

```bash
openclaw-agent-status        # systemctl status
openclaw-agent-logs          # journalctl -f
openclaw-agent-logs -n 50   # last 50 lines
```

You should see:
```
[gateway] listening on ws://127.0.0.1:3400
[gateway] running in Nix mode (config managed externally)
[discord] logged in to discord as <bot_name>
```

## Customizing the Agent

### Workspace files

The `workspace/` directory in this repo contains the agent's identity and behavior files. These are symlinked read-only into the runtime workspace:

| File | Purpose |
|------|---------|
| `AGENTS.md` | Agent identity and project context |
| `IDENTITY.md` | One-line identity |
| `SOUL.md` | Personality and tone |
| `BOOTSTRAP.md` | Startup instructions |
| `HEARTBEAT.md` | Periodic heartbeat instructions |

Edit these to change how the agent behaves, then redeploy.

### Skills

Skills are markdown files in `workspace/skills/<name>/SKILL.md` that teach the agent specific workflows (e.g., guided issue creation).

To add a skill:
1. Create `workspace/skills/<name>/SKILL.md`
2. Write the instructions
3. If the skill needs CLI tools, add them to `extraTools` in your config
4. Redeploy

### Extra config

Any additional `openclaw.json` fields can be set via `extraConfig`:

```nix
services.openclaw-agent.extraConfig = {
  agents.defaults.heartbeat.every = "0m";  # Disable heartbeats
};
```

## Module Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable the OpenClaw agent service |
| `dataDir` | path | `/var/lib/openclaw-agent` | Runtime state directory |
| `user` / `group` | string | `openclaw` | Service user/group |
| `envFile` | path | `null` | Path to secrets env file |
| `gatewayPort` | int | `3400` | Gateway HTTP/WS port (localhost only) |
| `maxConcurrent` | int | `4` | Max concurrent agent runs |
| `maxConcurrentSubagents` | int | `8` | Max concurrent subagent runs |
| `extraTools` | list | `[ gh ]` | Extra packages in gateway PATH |
| `githubApp.enable` | bool | `false` | Enable GitHub App token auth (replaces static PAT) |
| `githubApp.appId` | string | `""` | GitHub App ID |
| `githubApp.installationId` | string | `""` | GitHub App Installation ID |
| `githubApp.privateKeyFile` | path | `.../github-app.pem` | Path to App private key PEM file |
| `discord.enable` | bool | `true` | Enable Discord channel |
| `discord.guilds` | attrs | `{ "*" = { requireMention = true; }; }` | Guild config |
| `extraConfig` | attrs | `{}` | Extra config merged into openclaw.json |

## Updating

When this repo updates (new workspace files, module changes, gateway bump):

```bash
nix flake lock --update-input nix-openclaw
nixos-rebuild switch --flake .#myhost
```

## Rollback

```bash
nixos-rebuild switch --rollback
```

State in the data directory is preserved — only the service binary and Nix-managed config change.

## Runtime File Layout

```
/var/lib/openclaw-agent/
├── openclaw.json              # Config (Nix-generated + runtime wizard/meta)
├── .env                       # Secrets
├── .openclaw/
│   └── identity/device.json   # Device keypair (generated once, DO NOT DELETE)
├── workspace/                 # Read-only symlinks → Nix store
│   ├── AGENTS.md
│   ├── IDENTITY.md
│   ├── SOUL.md
│   └── skills/
├── docs/reference/templates/  # Workaround copies of workspace files
└── state/                     # Runtime-mutable (sessions, cron, agent state)
```

**Nix manages:** `workspace/` symlinks, `openclaw.json` generation, systemd service, helper scripts.

**Gateway manages:** `state/`, `.openclaw/`, session files, runtime config fields.

## Dev Workspaces

Ephemeral development environments via NixOS containers (systemd-nspawn). Each workspace is an isolated container with the full dev toolchain — git, node, nix, gh, claude code — connected via SSH.

### Setup

Add to your NixOS config:

```nix
# flake.nix inputs
claude-code-nix.url = "github:sadjow/claude-code-nix";

# In nixosModules
nixosModules.dev-workspaces = import ./workspace.nix {
  claude-code = claude-code-nix.packages.${system}.default;
};
```

```nix
# configuration.nix
services.dev-workspaces = {
  enable = true;
  slots = 4;  # Number of concurrent workspaces
};

networking.nat.externalInterface = "ens3";  # Your host's external interface
```

### Create the workspace secrets file

```bash
mkdir -p /var/lib/workspaces
cat > /var/lib/workspaces/.env << 'EOF'
ANTHROPIC_API_KEY=sk-ant-...
EOF
chmod 600 /var/lib/workspaces/.env
```

`ANTHROPIC_API_KEY` is required for `workspace-run` (headless Claude agent sessions). When `githubApp` is enabled on the agent, `GITHUB_TOKEN`/`GH_TOKEN` are injected into this file automatically by the token refresh timer.

### Usage

```bash
# Create a workspace (fetches SSH keys from GitHub)
workspace-create --repo opencouncil-tasks --github-user kouloumos

# SSH into it
workspace-ssh 1
# or remotely: ssh -p 2201 dev@<server-ip>

# Inside the container
cd repo && nix develop
npm test

# Run a headless Claude agent
workspace-run --slot 1 --prompt "Fix the failing tests" --max-turns 10

# Monitor the agent
workspace-status --slot 1           # summary + last 30 lines
workspace-status --slot 1 --full    # parsed messages and tool use
workspace-status --slot 1 -f        # follow live output

# Cleanup
workspace-destroy 1

# View past sessions
workspace-sessions --last 5
workspace-session <session-id>
```

### Workspace Scripts Reference

| Script | Description |
|--------|-------------|
| `workspace-create` | Create workspace from repo + GitHub SSH keys |
| `workspace-destroy` | Archive session data and destroy workspace |
| `workspace-list` | Show all slots with status |
| `workspace-ssh` | SSH into a workspace container |
| `workspace-run` | Start headless Claude agent in container |
| `workspace-status` | Monitor running agent (status, logs, follow) |
| `workspace-sessions` | List past sessions |
| `workspace-session` | Show full session details + git activity |

### `workspace-run` Options

| Option | Description |
|--------|-------------|
| `--slot N` | Workspace slot number (required) |
| `--prompt "..."` | Task prompt for Claude (required) |
| `--max-turns N` | Limit agentic turns |
| `--max-budget N` | Cost cap in USD |
| `--resume <id>` | Resume a previous Claude session |
| `--allowed-tools` | Restrict tool access |

### Architecture

- **Ephemeral rootfs** — container system resets on stop, only `/workspace` persists
- **Shared /nix** — bind-mounted from host, zero package duplication
- **Git worktrees** — bare repo cloned once, subsequent workspaces are instant
- **Session tracking** — git activity, container journal, and Claude session data archived on destroy
- **Private networking** — each container on its own subnet, SSH via port forwarding (2201-2204)
- **Memory capped** at 1GB per container

### File Layout

```
/var/lib/workspaces/
├── .env                      # Secrets (ANTHROPIC_API_KEY, GITHUB_TOKEN)
├── repos/                    # Shared bare repos
│   └── opencouncil-tasks.git
├── ws-1/                     # Active workspace slot 1
│   ├── .session-id
│   ├── .ssh/authorized_keys
│   └── repo/                 # Git worktree
└── sessions/                 # Archived sessions
    └── 1-20260222T1430/
        ├── session.json      # Metadata (slot, repo, user, timing, agent runs)
        ├── git-summary.txt   # Commits and diff stats
        ├── journal.log       # Container journal export
        ├── run-*.jsonl       # Claude stream-json output logs
        └── claude-data/      # Claude session data (if present)
```

## Agent Orchestration

The bot uses two skills to orchestrate development work through the workspace containers:

### plan-task

Triggered when someone asks to plan work on a task or GitHub issue. The bot:

1. Creates a Discord thread for discussion
2. Fetches the GitHub issue (or creates one)
3. Spins up a workspace container
4. Runs a planning agent that reads the codebase and produces a numbered implementation plan
5. Posts the plan for review — humans give feedback or approve
6. On approval, posts the final plan to the GitHub issue

### execute-plan

Takes an approved plan and implements it. The bot:

1. Runs a worker agent in the workspace with the approved plan
2. The agent implements each step as an atomic commit
3. Runs tests, creates a PR
4. Posts the PR link and run stats (cost, turns, duration) to the thread and GitHub issue
5. Destroys the workspace

### Full flow

```
Human: "Work on issue #42"
  → plan-task: thread, workspace, planning agent, discussion
  → Human: "approved"
  → execute-plan: worker agent, atomic commits, PR
  → Summary: PR link, cost, duration
```

Skills are defined in `workspace/skills/{plan-task,execute-plan}/SKILL.md`.

## PR Preview Deployments

The server hosts per-PR preview environments for both the main app and the tasks API. When a PR is opened against `main`, GitHub Actions builds it, pushes to Cachix, and deploys a preview instance on the server.

### How it works

1. PR opened → GitHub Actions builds the Nix package and pushes to Cachix
2. Action SSHs into the server and runs the preview-create script
3. Caddy automatically provisions TLS and reverse-proxies to the instance
4. PR comment is posted with the preview URL
5. On PR close/merge, the preview is destroyed

### URLs

- **opencouncil** (main app): `https://pr-N.preview.opencouncil.gr` (base port 3000+N)
- **opencouncil-tasks** (API): `https://pr-N.tasks.opencouncil.gr` (base port 4000+N)

### Management

```bash
# List active previews
opencouncil-tasks-preview-list

# View logs for PR #123
opencouncil-tasks-preview-logs 123

# Manual create/destroy
sudo opencouncil-tasks-preview-create <PR_NUM> <NIX_STORE_PATH>
sudo opencouncil-tasks-preview-destroy <PR_NUM>
```

The preview modules themselves are defined in the [opencouncil](https://github.com/schemalabz/opencouncil) and [opencouncil-tasks](https://github.com/schemalabz/opencouncil-tasks) repos and imported as flake inputs. This repo enables them and provides the host-level configuration (Caddy, ports, env files).

## Note on nixpkgs

This module depends on `nix-openclaw` (upstream), which pins its own nixpkgs to match their binary cache. **Do not** use `follows = "nixpkgs"` for the `nix-openclaw` input — overriding their pin forces a from-source rebuild of the gateway (~1.2GB CUDA dependencies) that will OOM on small VPS instances.
