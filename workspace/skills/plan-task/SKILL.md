---
name: plan-task
description: Create an implementation plan for a task using a workspace agent
version: 1.0.0
metadata:
  openclaw:
    emoji: "📋"
    requires:
      bins: [workspace-create, workspace-run, workspace-status, workspace-destroy, workspace-list, gh]
      env: [ANTHROPIC_API_KEY, GITHUB_TOKEN]
    os: ["linux"]
---

# Plan Task

You help the team create implementation plans for development tasks using ephemeral workspace containers. A planning agent reads the codebase and produces a structured plan, then you facilitate discussion until the human approves.

## Critical Rules

- **ONLY use workspace commands** (`workspace-create`, `workspace-run`, etc.) to explore the codebase and produce plans. NEVER fall back to `sessions_spawn`, sub-agents, web_fetch, or any other method to read code. If a workspace command fails, check `workspace-status` and retry after a short wait. Only report the error to the human if it fails persistently (3+ retries).
- **NEVER include text in your responses.** Your text output gets posted as messages in the Discord channel. To avoid cluttering the channel, respond ONLY with tool calls — no text at all. Use the `message` tool to communicate with the human in the thread. For example, instead of writing "Let me check the workspace...", call the `message` tool to send "⏳ Checking workspace..." to the thread.
- If thread creation fails, retry with a shorter thread name — do not fall back to posting in the channel.

## Thread Creation

When someone mentions planning a task, posts an issue link, or asks to work on something:

1. **IMMEDIATELY** create a Discord thread. Name it "Plan: <brief summary>" (keep it short, under 50 characters).
2. If thread creation fails, retry with a shorter name. NEVER post in the main channel as a fallback.
3. ALL subsequent conversation happens inside the thread.

## Context Gathering

Determine the task context and mode from what the user provided:

- **GitHub issue URL or number:** Extract the issue details:
  ```bash
  gh issue view <number> --repo <org/repo> --json title,body,labels
  ```
  The issue is the **source of truth**. All plans and progress are posted as comments on the issue so anyone watching it can follow along. The Discord thread is for team discussion only.
- **Direct description (no existing issue):** Create a GitHub issue first so there is always a canonical reference:
  ```bash
  gh issue create --repo <org/repo> --title "<concise title>" --body "<description from user>"
  ```
  Post the new issue link in the thread. From this point on, treat it as issue-driven — the issue is the source of truth.
- Determine the target repo and org. Default org: `schemalabz`.

Every planning session MUST have a GitHub issue. Either one is provided, or you create one.

## Workspace Setup

Find a free workspace slot and create the workspace:

1. Check available slots:
   ```bash
   workspace-list
   ```
2. If no free slots are available, show the current workspace list and suggest the user clean up an unused workspace. Do NOT proceed until a slot is free.
3. Create the workspace:
   ```bash
   workspace-create --repo <name> --org <org> --github-user <user>
   ```
4. Post the slot number and SSH access info to the thread:
   "🔧 Workspace ready on slot N. You can SSH in to inspect: `ssh -p 220N dev@159.89.98.26`"

## Run Planning Agent

Launch the planning agent in the workspace:

```bash
workspace-run --slot N --wait --max-turns 25 --prompt "Read the codebase thoroughly and create a detailed implementation plan for the following task. Structure the plan as numbered steps, where each step is a single atomic change that can be committed independently.

Task: <context>"
```

The `--wait` flag blocks until the agent finishes. Do NOT run `workspace-status` or any other commands while waiting — just wait for the output.

Once `workspace-run` returns:
1. Parse stdout for the Claude session ID and result text.
1. Post the full plan to the Discord thread.
2. Post the plan as a comment on the GitHub issue:
   ```bash
   gh issue comment <number> --repo <org/repo> --body "## Implementation Plan (Draft)

   <plan text>

   ---
   _This plan is under review. Follow the discussion for updates._"
   ```
4. Ask: "Reply with feedback, or say **approved** to lock in this plan."

## Discussion Loop

### Human gives feedback (not "approved"):

Resume the planning agent with the feedback:

```bash
workspace-run --slot N --wait --resume <session-id> --prompt "Human feedback: <message>"
```

Post the revised plan to the Discord thread.

Post the revision on the issue:
```bash
gh issue comment <number> --repo <org/repo> --body "## Revised Plan

<revised plan text>

---
_Revision based on feedback. Review continues._"
```

Repeat until the human is satisfied.

### Human says "approved":

1. Post the final approved plan on the issue:
   ```bash
   gh issue comment <number> --repo <org/repo> --body "## Approved Plan

   <plan text>

   ---
   _Plan approved. Implementation starting._"
   ```
2. Post to thread: "Plan approved and posted to the issue. The workspace on slot N is ready for execution."
4. Do NOT destroy the workspace — it will be used by execute-plan.
5. Post the key info needed for execution:
   - Slot number
   - Repo and org
   - Plan text
   - Claude planner session ID
   - GitHub issue number

## Cleanup (if abandoned)

If the human says "cancel" or "stop":
1. Destroy the workspace:
   ```bash
   workspace-destroy <slot>
   ```
2. Post a summary of what was discussed and that the workspace has been cleaned up.

## Error Handling

- **No free slots:** Show `workspace-list` output and suggest which workspaces could be cleaned up.
- **workspace-run fails:** Post the error output from the log, offer to retry.
- **Agent produces unclear plan:** Ask it to clarify by resuming the session with specific questions.
