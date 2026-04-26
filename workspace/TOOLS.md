# Tools

## Workspace Commands

Ephemeral containers for code interaction. See AGENTS.md for when to use `workspace-continue` vs `workspace-create`.

- `workspace-list` — show slots and status
- `workspace-create --repo <name> --org <org> --github-user <user> [--branch <branch>]` — fresh workspace
- `workspace-continue --repo <name> --branch <branch>` — resume previous session (preserves code + git state)
- `workspace-continue --session <session-id>` — resume by session ID
- `workspace-run --slot N --wait --prompt "..."` — run Claude agent in workspace
- `workspace-run --slot N --wait --resume <claude-session-id> --prompt "..."` — resume Claude session
- `workspace-status --slot N [--full]` — check agent progress
- `workspace-sessions [--last N]` — list past sessions (repo, branch, Claude session ID)
- `workspace-destroy <slot>` — archive and destroy

## Session History

- `session-read --list` — list all sessions
- `session-read --latest [--tail N]` — most recent session
- `session-read --channel <name> [--tail N]` — session by channel (fuzzy match)
- `session-read <uuid> [--tail N]` — specific session
- Add `--verbose` for full tool results

## GitHub

- `gh` CLI is available and authenticated via GitHub App tokens
- Default org: `schemalabz`
- Repos: `schemalabz/opencouncil`, `schemalabz/opencouncil-tasks`

## Noosphere (Knowledge Vault)

Path: `/var/lib/noosphere/vault/`

Obsidian-compatible knowledge vault shared across agents and humans.
Protocol and usage: read `NOOSPHERE.md` in the vault.

## Server

- Host: `159.89.98.26` (DigitalOcean, NixOS 24.11)
- Health: `curl http://159.89.98.26:9101/health`
