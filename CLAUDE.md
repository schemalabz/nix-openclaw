# CLAUDE.md

## Infrastructure

- Server: `ssh root@159.89.98.26` (DigitalOcean, NixOS 24.11)
- Host config: `hosts/preview/configuration.nix`
- Full NixOS config is built from this repo's flake (`nixosConfigurations.preview`)

## Deployment

- **Auto-deploy**: push to `main` triggers GitHub Actions deploy (requires `DEPLOY_SSH_KEY` secret)
- **Manual deploy**: `make deploy` (builds on the server via SSH)
- **Dry run**: `make dry-run` (previews changes without applying)
- **Direct**: `nixos-rebuild switch --flake .#preview --target-host root@159.89.98.26 --build-host root@159.89.98.26`
- **Health check**: `make health` or `curl http://159.89.98.26:9101/health` — shows deployed git revision, NixOS version, and service statuses
- After deploy, verify with: `make health` or `ssh root@159.89.98.26 openclaw-agent-status`

## Context System

- Read `CONTEXT.md` and files in `.context/` at the start of every session to understand prior work
- Use the `.context/` convention (dated files with YAML frontmatter) to preserve session context
- Propose improvements to how we keep context when you see opportunities for better efficiency, but always discuss before changing the system
