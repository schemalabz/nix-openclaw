# nix-openclaw

NixOS module for running an [OpenClaw](https://github.com/openclaw/openclaw) agent gateway as a system-level systemd service. Built for the [Schema Labs](https://github.com/schemalabz) / [OpenCouncil](https://github.com/schemalabz/opencouncil) project.

## What This Is

A declarative NixOS module that wraps the `openclaw-gateway` binary and manages:

- **Systemd service** with security hardening (NoNewPrivileges, PrivateTmp, ProtectHome)
- **Workspace files** (AGENTS.md, IDENTITY.md, SOUL.md, skills/) — tracked in git, symlinked into the runtime workspace as read-only
- **openclaw.json generation** from Nix attrsets, with preservation of runtime-mutable fields (wizard/meta state)
- **Workaround** for the [nix-openclaw missing templates bug](https://gist.github.com/gudnuf/8fe65ca0e49087105cb86543dc8f0799)
- **Helper scripts** for status, logs, restart

## What OpenClaw Does

OpenClaw is an autonomous AI agent platform. The gateway runs as a long-lived process that:

- **Connects to Discord** as a bot — responds to mentions, manages threads, registers slash commands
- **Runs an LLM agent** (Anthropic Claude) with tool use — can execute shell commands (`gh`, etc.), read/write files, create sub-agents
- **Loads skills** — markdown files that teach the agent specific workflows (e.g., guided GitHub issue creation)
- **Maintains sessions** — per-channel conversation history with context management
- **Heartbeat** — periodic LLM call (default every 30min) that reads `HEARTBEAT.md` and follows instructions. Currently a no-op stub; can be used for proactive monitoring, scheduled checks, etc.
- **Exposes HTTP/WS API** on localhost — for the TUI, CLI tools, and webhooks

### What It Does When Idle

Even with no Discord activity, the gateway:

1. Maintains a WebSocket connection to Discord (reconnects on close with backoff)
2. Fires heartbeat polls every 30 minutes
3. Manages session state and cron jobs (currently empty)

### Runtime File Layout

```
/var/lib/openclaw-agent/
├── openclaw.json              # Config (Nix-generated + runtime wizard/meta fields)
├── openclaw.json.bak          # Auto-backup before config mutations
├── .env                       # Secrets (DISCORD_BOT_TOKEN, ANTHROPIC_API_KEY, etc.)
├── .openclaw/
│   ├── identity/device.json   # Generated once — device keypair (DO NOT DELETE)
│   └── canvas/index.html      # Gateway's built-in canvas UI
├── workspace/                 # Read-only symlinks to Nix store
│   ├── AGENTS.md              # Agent identity and project context
│   ├── IDENTITY.md            # Short identity line
│   ├── SOUL.md                # Personality/tone
│   ├── TOOLS.md               # Available tools description
│   ├── BOOTSTRAP.md           # Startup instructions
│   ├── HEARTBEAT.md           # Heartbeat poll instructions
│   ├── MEMORY.md              # Memory instructions
│   ├── USER.md                # User description
│   └── skills/
│       └── create-issue/
│           └── SKILL.md       # Issue creation workflow
├── docs/reference/templates/  # Copies of workspace .md files (gateway bug workaround)
└── state/                     # Runtime-mutable (sessions, cron, agent state)
    ├── agents/main/sessions/  # Conversation history (.jsonl files)
    ├── credentials/           # Stored credentials
    └── cron/jobs.json         # Scheduled jobs (currently empty)
```

**Nix manages:** `workspace/` files (read-only symlinks), `openclaw.json` generation, systemd service, helper scripts.

**Gateway manages:** `state/`, `.openclaw/`, `docs/reference/templates/`, `openclaw.json` wizard/meta fields, session files.

## Setup

### Prerequisites

- NixOS droplet (or any NixOS machine)
- Discord bot token ([Discord Developer Portal](https://discord.com/developers/applications))
- Anthropic API key
- GitHub token (for `gh` CLI in skills)

### 1. Discord Developer Portal

1. Create a new application at https://discord.com/developers/applications
2. Go to **Bot** → copy the bot token
3. Enable **Privileged Gateway Intents**: Message Content Intent, Server Members Intent
4. Go to **OAuth2** → URL Generator → select scopes: `bot`, `applications.commands`
5. Select permissions: Send Messages, Send Messages in Threads, Create Public Threads, Add Reactions, Read Message History, Embed Links
6. Use the generated URL to invite the bot to your server

### 2. Droplet Configuration

**`/etc/nixos/flake.nix`:**

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nix-openclaw.url = "github:schemalabz/nix-openclaw";
  };

  outputs = { self, nixpkgs, nix-openclaw, ... }: {
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

**`/etc/nixos/configuration.nix`:**

```nix
{
  services.openclaw-agent = {
    enable = true;
    envFile = "/var/lib/openclaw-agent/.env";
  };
}
```

### 3. Secrets

Create the env file on the droplet:

```bash
cat > /var/lib/openclaw-agent/.env << 'EOF'
DISCORD_BOT_TOKEN=your_discord_bot_token
ANTHROPIC_API_KEY=your_anthropic_api_key
GITHUB_TOKEN=your_github_pat
GH_TOKEN=your_github_pat
OPENCLAW_GATEWAY_TOKEN=any_random_uuid
EOF
chmod 600 /var/lib/openclaw-agent/.env
```

`GH_TOKEN` is the same as `GITHUB_TOKEN` — OpenClaw uses one, `gh` CLI uses the other.

### 4. Deploy

```bash
nixos-rebuild switch --flake /etc/nixos#myhost
```

### 5. Verify

```bash
openclaw-agent-status        # systemctl status
openclaw-agent-logs           # journalctl -f
openclaw-agent-logs -n 50    # last 50 lines
```

Look for:
```
[heartbeat] started
[gateway] agent model: anthropic/claude-opus-4-5
[gateway] listening on ws://127.0.0.1:3400
[gateway] running in Nix mode (config managed externally)
[discord] logged in to discord as <bot_id>
```

## Updating

When workspace files or module config change in this repo:

```bash
nix flake update nix-openclaw --flake /etc/nixos
nixos-rebuild switch --flake /etc/nixos#myhost
```

## Rollback

**Disable the agent:**
```nix
services.openclaw-agent.enable = false;
```
Then `nixos-rebuild switch`. The service stops, helper scripts are removed. State in `/var/lib/openclaw-agent/` is preserved.

**Rollback to previous NixOS generation:**
```bash
nixos-rebuild switch --rollback
```

## Adding Skills

Skills are markdown files in `workspace/skills/<name>/SKILL.md`. They teach the agent a specific workflow.

To add a new skill:

1. Create `workspace/skills/<name>/SKILL.md`
2. Write instructions the agent should follow
3. If the skill needs CLI tools, add them to `extraTools` in your NixOS config
4. Commit, push, update flake on droplet, rebuild

The module automatically symlinks all skills into the workspace.

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
| `extraTools` | list of packages | `[ gh ]` | Extra packages in gateway PATH |
| `discord.enable` | bool | `true` | Enable Discord channel |
| `discord.guilds` | attrs | `{ "*" = { requireMention = true; }; }` | Guild config |
| `extraConfig` | attrs | `{}` | Extra config merged into openclaw.json |

## Architecture

```
┌─────────────────────────────────────────────────┐
│  NixOS Module (this repo)                       │
│  - Generates openclaw.json from Nix attrsets    │
│  - Symlinks workspace files from Nix store      │
│  - Manages systemd service + security           │
└──────────────┬──────────────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────────────┐
│  openclaw-gateway (from nix-openclaw flake)     │
│  - Discord WebSocket connection                 │
│  - LLM agent runtime (Anthropic Claude)         │
│  - Tool execution (gh, shell commands)           │
│  - Session management + heartbeat               │
│  - Skills loading from workspace/               │
└──────────────┬──────────────┬───────────────────┘
               │              │
               ▼              ▼
         Discord API    GitHub API (via gh)
```
