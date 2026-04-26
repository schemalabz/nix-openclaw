---
name: plan-task
description: Create an implementation plan for a task using a workspace agent
version: 2.0.0
metadata:
  openclaw:
    emoji: "📋"
    requires:
      bins: [workspace-create, workspace-continue, workspace-run, workspace-status, workspace-destroy, workspace-list, gh]
      env: [ANTHROPIC_API_KEY]
    os: ["linux"]
---

# Plan Task

Create implementation plans for development tasks using workspace containers.

## Trigger

Someone mentions planning a task, posts an issue link, or asks to work on something.

## Workflow

### 1. Create thread

Name it "Plan: <brief summary>" (under 50 chars). All conversation happens in the thread.

### 2. Ensure a GitHub issue exists

- **Issue URL/number given:** Fetch details with `gh issue view`.
- **No issue:** Create one with `gh issue create`, post the link in the thread.

The issue is the source of truth. Plans and progress are posted as issue comments.

### 3. Set up workspace

Use `workspace-continue` for previous work on the same repo/branch, `workspace-create` for new work. See TOOLS.md for commands.

Post slot number and SSH access to the thread.

### 4. Run planning agent

```bash
workspace-run --slot N --wait --max-turns 25 --prompt "Read the codebase thoroughly and create a detailed implementation plan for the following task. Structure the plan as numbered steps, where each step is a single atomic change that can be committed independently.

Task: <context>"
```

`--wait` blocks until done. Don't poll while waiting.

### 5. Post the plan

1. Post the full plan to the Discord thread.
2. Post as a comment on the GitHub issue:
   ```bash
   gh issue comment <number> --repo <org/repo> --body "## Implementation Plan (Draft)

   <plan text>

   ---
   _This plan is under review._"
   ```
3. Ask: "Reply with feedback, or say **approved** to lock in this plan."

### 6. Discussion loop

**Feedback:** Resume the planning agent with the feedback:
```bash
workspace-run --slot N --wait --resume <session-id> --prompt "Human feedback: <message>"
```
Post revised plan to thread and issue. Repeat until approved.

**Approved:**
1. Post final plan on the issue as "## Approved Plan"
2. Post key info for execution: slot, repo/org, plan text, Claude session ID, issue number
3. Do NOT destroy the workspace — it will be used by execute-plan.

### 7. Cancelled

If the human says "cancel": destroy the workspace and post a summary.

## Error handling

- **No free slots:** Show `workspace-list`, suggest cleanup.
- **workspace-run fails:** Post error, offer retry.
- **Unclear plan:** Resume session with specific questions.
