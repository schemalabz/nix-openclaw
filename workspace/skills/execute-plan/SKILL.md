---
name: execute-plan
description: Execute an approved implementation plan in a workspace container
version: 1.0.0
metadata:
  openclaw:
    emoji: "⚡"
    requires:
      bins: [workspace-run, workspace-status, workspace-destroy, workspace-list, gh]
      env: [ANTHROPIC_API_KEY, GITHUB_TOKEN]
    os: ["linux"]
---

# Execute Plan

You take an approved implementation plan and execute it in an ephemeral workspace container. A worker agent implements the plan with atomic commits, you monitor progress and post updates, and a PR is created when done.

## Critical Rules

- **ONLY use workspace commands** (`workspace-run`, `workspace-status`, etc.) to execute plans. NEVER fall back to `sessions_spawn`, sub-agents, or direct code editing. If a workspace command fails, check `workspace-status` and retry after a short wait. Only report the error to the human if it fails persistently (3+ retries).
- **NEVER include text in your responses.** Your text output gets posted as messages in the Discord channel. To avoid cluttering the channel, respond ONLY with tool calls — no text at all. Use the `message` tool to communicate with the human in the thread. For example, instead of writing "Let me check the results...", call the `message` tool to send the update to the thread. If thread creation fails, retry with a shorter name.
- **Always use the workspace infrastructure** even if you think you could solve it faster another way. The workspace containers provide isolation, git history, and reproducibility.

## Trigger

This skill activates in two ways:

- **Chained from plan-task:** After a plan is approved, the bot starts execution automatically using the existing workspace.
- **Invoked directly:** A human says "execute this plan on slot N: <plan text>".

If no thread exists, create one: "Execute: <brief summary>".

## Validate Prerequisites

Before starting:

1. Verify the workspace is running:
   ```bash
   workspace-list
   ```
   Confirm slot N is active.
2. If no workspace exists, create one:
   ```bash
   workspace-create --repo <name> --org <org> --github-user <user>
   ```
3. Confirm the plan text, target repo/org, and GitHub issue number are known. Every execution is tied to a GitHub issue (created by plan-task if one didn't exist).

## Run Worker Agent

Launch the worker agent:

```bash
workspace-run --slot N --wait --max-turns 60 --prompt "You are a worker agent. Implement the following approved plan precisely.

CRITICAL INSTRUCTIONS:
- Work through the plan step by step
- After completing EACH step, make an atomic git commit with a message like 'feat: step 1 - <description>'
- Do NOT combine multiple steps into one commit
- If a step is unclear, implement your best interpretation and note it in the commit message
- When all steps are complete, run the test suite if one exists
- Finally, create a PR:
  gh pr create --repo <org/repo> --title '<concise title>' --body '<plan summary + what was implemented>'

PLAN:
<approved plan text>"
```

Post to thread: "Worker started on slot N. This may take a while. SSH access: `ssh -p 220N dev@159.89.98.26`"

The `--wait` flag blocks until the agent finishes. Do NOT run `workspace-status` or any other commands while waiting — just wait for the output. When `workspace-run` returns, the output contains the result text, Claude session ID, cost, turns, and duration.

## Completion

When `workspace-run --wait` returns:

1. Parse the output for a PR URL (look for `github.com/.../pull/` in the result text).
2. Post the PR link and run stats (cost, turns, duration) to the Discord thread.
3. Post a completion comment on the GitHub issue:
   ```bash
   gh issue comment <number> --repo <org/repo> --body "## Implementation Complete

   PR: <PR URL>

   **Commits:**
   <list of commits>

   ---
   _Automated implementation of the approved plan._"
   ```
4. Destroy the workspace:
   ```bash
   workspace-destroy <slot>
   ```
5. Post a summary to the thread with all available stats from the workspace-run output:
   - PR link
   - Cost (from the "Cost:" line in workspace-run output)
   - Turns used
   - Duration
   - Number of commits

## Human Intervention

- **"pause" or "stop":** Kill the worker process, keep the workspace alive, inform the human.
- **"resume":** Re-run workspace-run in the same workspace (fresh worker session).
- **"destroy":** Destroy the workspace and post a summary:
  ```bash
  workspace-destroy <slot>
  ```
- **SSH access:** The human can SSH in at any time:
  ```
  ssh -p 220N dev@159.89.98.26
  ```

## Error Handling

- **Worker fails:** Post the error from workspace-status log, offer to retry or provide SSH access for manual debugging.
- **Tests fail:** Post the test output to the thread, ask the human how to proceed (fix and retry, or create PR as-is with a note).
- **No progress for 10+ minutes:** Alert the human in the thread, offer to abort the worker.
