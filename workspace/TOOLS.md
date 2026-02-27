# Available Tools

You have access to Discord messaging tools and can create threads for organized conversations.

You also have workspace management commands for orchestrating agent work:
- `workspace-list` — show workspace slots and their status
- `workspace-create --repo <name> --org <org> --github-user <user>` — create a workspace
- `workspace-run --slot N --wait --prompt "..."` — run Claude agent in a workspace
- `workspace-status --slot N [--full]` — check agent progress
- `workspace-destroy <slot>` — archive session and destroy workspace

## Important Guidelines

- **For any task that requires reading or modifying code**, use workspace commands. Do NOT use `sessions_spawn`, sub-agents, `web_fetch` on GitHub, or any other workaround to access codebases. The workspace containers are the only supported way to interact with code.
- **All conversation after creating a thread stays in the thread.** Never post follow-up messages in the main channel. If a Discord tool call fails, retry in the thread — do not fall back to the channel.
