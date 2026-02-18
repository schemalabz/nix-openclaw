# nix-openclaw

NixOS module for running an [OpenClaw](https://github.com/openclaw/openclaw) agent gateway as a system-level systemd service. Built for the [Schema Labs](https://github.com/schemalabz) / [OpenCouncil](https://github.com/schemalabz/opencouncil) project.

The module wraps the `openclaw-gateway` binary and manages:

- Systemd service with security hardening
- Workspace files (agent identity, skills) — tracked in git, symlinked read-only
- `openclaw.json` generation from Nix, preserving runtime-mutable fields
- Helper scripts (`openclaw-agent-status`, `openclaw-agent-logs`, `openclaw-agent-restart`)

## Prerequisites

- A NixOS machine (tested on 24.11)
- Discord bot token ([Developer Portal](https://discord.com/developers/applications))
- Anthropic API key
- GitHub token (for `gh` CLI in agent skills)

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

### 3. Create the secrets file on the server

```bash
mkdir -p /var/lib/openclaw-agent
cat > /var/lib/openclaw-agent/.env << 'EOF'
DISCORD_BOT_TOKEN=your_discord_bot_token
ANTHROPIC_API_KEY=your_anthropic_api_key
GITHUB_TOKEN=your_github_pat
GH_TOKEN=your_github_pat
OPENCLAW_GATEWAY_TOKEN=any_random_uuid
EOF
chmod 600 /var/lib/openclaw-agent/.env
```

`GH_TOKEN` is the same value as `GITHUB_TOKEN` — OpenClaw uses one, the `gh` CLI uses the other.

### 4. Deploy

```bash
nixos-rebuild switch --flake .#myhost
```

### 5. Verify

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

## Note on nixpkgs

This module depends on `nix-openclaw` (upstream), which pins its own nixpkgs to match their binary cache. **Do not** use `follows = "nixpkgs"` for the `nix-openclaw` input — overriding their pin forces a from-source rebuild of the gateway (~1.2GB CUDA dependencies) that will OOM on small VPS instances.
