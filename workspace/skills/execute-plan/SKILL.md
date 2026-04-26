---
name: execute-plan
description: Execute an approved implementation plan in a workspace container
version: 2.0.0
metadata:
  openclaw:
    emoji: "⚡"
    requires:
      bins: [workspace-run, workspace-continue, workspace-status, workspace-destroy, workspace-list, gh]
      env: [ANTHROPIC_API_KEY]
    os: ["linux"]
---

# Execute Plan

Execute an approved implementation plan with atomic commits and a PR.

## Trigger

- **Chained from plan-task:** After a plan is approved, execution starts using the existing workspace.
- **Direct:** Human says "execute this plan on slot N: <plan text>".

## Workflow

### 1. Create thread (if none exists)

Name it "Execute: <brief summary>". All conversation in the thread.

### 2. Verify workspace

Check `workspace-list`. If no workspace, set one up — `workspace-continue` for previous work, `workspace-create` for new. See TOOLS.md.

### 3. Run worker agent

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

Post to thread: "Worker started on slot N. SSH: `ssh -p 220N dev@159.89.98.26`"

`--wait` blocks until done. Don't poll while waiting.

### 4. Completion

When `workspace-run --wait` returns:

1. Parse output for PR URL.
2. Post PR link and run stats (cost, turns, duration) to thread.
3. Comment on the GitHub issue:
   ```bash
   gh issue comment <number> --repo <org/repo> --body "## Implementation Complete

   PR: <PR URL>

   **Commits:**
   <list of commits>

   ---
   _Automated implementation of the approved plan._"
   ```
4. Do NOT destroy the workspace. Preserve state for follow-up work.
5. Post summary to thread: PR link, cost, turns, duration, commit count.

### 5. Human intervention

- **"pause" / "stop":** Kill the worker, keep workspace alive.
- **"resume":** Re-run `workspace-run` in the same workspace.
- **"destroy":** Destroy workspace, post summary.
- **SSH access:** `ssh -p 220N dev@159.89.98.26`

## Error handling

- **Worker fails:** Post error from log, offer retry or SSH access.
- **Tests fail:** Post output, ask how to proceed.
