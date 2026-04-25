# NixOS module for ephemeral dev workspaces via systemd-nspawn containers.
#
# Declares a fixed pool of container slots that can be dynamically
# assigned to developers or agents. Each container:
# - Ephemeral rootfs (resets on stop)
# - Bind-mounted /nix from host (zero duplication, nix develop works)
# - Bind-mounted /workspace from host (persists work across restarts)
# - Private network with SSH via port forwarding
# - Memory-capped at 1GB
#
# Management scripts: workspace-create, workspace-destroy, workspace-list,
# workspace-ssh, workspace-sessions, workspace-session, workspace-run,
# workspace-status

{ claude-code }:

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.dev-workspaces;

  # Slot numbers: 1..N
  slotNumbers = genList (i: i + 1) cfg.slots;

  containerName = n: "workspace-${toString n}";

  workspaceCreate = pkgs.writeShellScriptBin "workspace-create" ''
    set -euo pipefail

    REPO=""
    GITHUB_USER=""
    BRANCH=""
    ORG=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --github-user) GITHUB_USER="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --org) ORG="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
      esac
    done

    if [[ -z "$REPO" || -z "$GITHUB_USER" ]]; then
      echo "Usage: workspace-create --repo <name> --github-user <user> [--branch <branch>] [--org <owner>]"
      echo ""
      echo "  --repo          Repository name (opencouncil or opencouncil-tasks)"
      echo "  --github-user   GitHub username (SSH keys fetched from github.com)"
      echo "  --branch        Git branch to checkout (default: main)"
      echo "  --org           GitHub org/owner (default: schemalabz)"
      exit 1
    fi

    ORG="''${ORG:-schemalabz}"
    REPO_URL="https://github.com/$ORG/$REPO.git"
    BRANCH="''${BRANCH:-main}"
    BASE_DIR="${cfg.workspacesDir}"
    SESSIONS_DIR="${cfg.sessionsDir}"

    # Find a free slot
    SLOT=""
    for n in ${concatMapStringsSep " " toString slotNumbers}; do
      STATE=$(systemctl show -p ActiveState --value "container@workspace-$n" 2>/dev/null || echo "inactive")
      if [[ "$STATE" == "inactive" || "$STATE" == "failed" ]]; then
        SLOT="$n"
        break
      fi
    done

    if [[ -z "$SLOT" ]]; then
      echo "Error: No free workspace slots available"
      echo "Use 'workspace-list' to see current status"
      exit 1
    fi

    CONTAINER="workspace-$SLOT"
    WS_DIR="$BASE_DIR/ws-$SLOT"
    SSH_PORT=$((${toString cfg.baseSSHPort} + SLOT))
    SESSION_ID="$SLOT-$(date -u +%Y%m%dT%H%M)"

    echo "==> Preparing workspace slot $SLOT..."

    # Clean and prepare host directory
    rm -rf "$WS_DIR"
    mkdir -p "$WS_DIR/.ssh"

    # Fetch GitHub SSH keys
    echo "==> Fetching SSH keys for $GITHUB_USER..."
    KEYS=$(${pkgs.curl}/bin/curl -sf "https://github.com/$GITHUB_USER.keys" || true)
    if [[ -z "$KEYS" ]]; then
      echo "    Warning: No SSH keys found for GitHub user '$GITHUB_USER'"
      echo "    You won't be able to SSH into the container"
    else
      echo "$KEYS" > "$WS_DIR/.ssh/authorized_keys"
      chmod 600 "$WS_DIR/.ssh/authorized_keys"
      KEY_COUNT=$(echo "$KEYS" | wc -l)
      echo "    Found $KEY_COUNT key(s)"
    fi

    # Bare repo setup (shared across workspaces, cloned once per org/repo)
    REPOS_DIR="$BASE_DIR/repos"
    BARE_DIR="$REPOS_DIR/$ORG/$REPO.git"
    mkdir -p "$REPOS_DIR/$ORG"

    if [[ ! -d "$BARE_DIR" ]]; then
      echo "==> Cloning bare repo for $REPO (first time)..."
      ${pkgs.git}/bin/git clone --bare "$REPO_URL" "$BARE_DIR" 2>&1 | sed 's/^/    /'
      # Configure fetch refspec so origin/* refs work with worktrees
      ${pkgs.git}/bin/git -C "$BARE_DIR" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
      ${pkgs.git}/bin/git -C "$BARE_DIR" fetch origin 2>&1 | sed 's/^/    /'
    else
      echo "==> Fetching latest for $REPO..."
      ${pkgs.git}/bin/git -C "$BARE_DIR" fetch origin 2>&1 | sed 's/^/    /'
    fi

    # Create worktree with a new branch based on the target branch
    WORKTREE_BRANCH="ws-$SESSION_ID"
    echo "==> Creating worktree (branch: $WORKTREE_BRANCH from origin/$BRANCH)..."
    ${pkgs.git}/bin/git -C "$BARE_DIR" worktree add "$WS_DIR/repo" -b "$WORKTREE_BRANCH" "origin/$BRANCH" 2>&1 | sed 's/^/    /'

    # Record starting commit for later diff
    START_COMMIT=$(${pkgs.git}/bin/git -C "$WS_DIR/repo" rev-parse HEAD)

    # Create session directory and metadata
    mkdir -p "$SESSIONS_DIR/$SESSION_ID"
    ${pkgs.jq}/bin/jq -n \
      --arg id "$SESSION_ID" \
      --argjson slot "$SLOT" \
      --arg org "$ORG" \
      --arg repo "$REPO" \
      --arg branch "$BRANCH" \
      --arg github_user "$GITHUB_USER" \
      --arg start_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson ssh_port "$SSH_PORT" \
      --arg start_commit "$START_COMMIT" \
      --arg worktree_branch "$WORKTREE_BRANCH" \
      '{id: $id, slot: $slot, org: $org, repo: $repo, branch: $branch, worktree_branch: $worktree_branch, github_user: $github_user, start_time: $start_time, ssh_port: $ssh_port, start_commit: $start_commit}' \
      > "$SESSIONS_DIR/$SESSION_ID/session.json"

    # Link slot to session
    echo "$SESSION_ID" > "$WS_DIR/.session-id"

    # Start container
    echo "==> Starting container $CONTAINER..."
    sudo nixos-container start "$CONTAINER"

    echo ""
    echo "==> Workspace ready!"
    echo "    Slot:     $SLOT"
    echo "    Repo:     $ORG/$REPO (base: $BRANCH)"
    echo "    Branch:   $WORKTREE_BRANCH"
    echo "    Session:  $SESSION_ID"
    echo "    SSH:      ssh -p $SSH_PORT -o StrictHostKeyChecking=no dev@127.0.0.1"
    echo "    Remote:   ssh -p $SSH_PORT -o StrictHostKeyChecking=no dev@159.89.98.26"
    echo ""
    echo "    Inside the container: cd repo && nix develop"
  '';

  workspaceDestroy = pkgs.writeShellScriptBin "workspace-destroy" ''
    set -euo pipefail

    if [[ $# -ne 1 ]]; then
      echo "Usage: workspace-destroy <slot>"
      exit 1
    fi

    SLOT="$1"
    CONTAINER="workspace-$SLOT"
    BASE_DIR="${cfg.workspacesDir}"
    WS_DIR="$BASE_DIR/ws-$SLOT"
    SESSIONS_DIR="${cfg.sessionsDir}"

    if ! systemctl is-active --quiet "container@$CONTAINER" 2>/dev/null; then
      echo "Warning: Container $CONTAINER is not running"
    fi

    # Read session ID
    SESSION_ID=""
    if [[ -f "$WS_DIR/.session-id" ]]; then
      SESSION_ID=$(cat "$WS_DIR/.session-id")
    fi

    if [[ -n "$SESSION_ID" && -d "$SESSIONS_DIR/$SESSION_ID" ]]; then
      SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"

      # Capture git activity (worktrees use a .git file, not directory)
      if [[ -e "$WS_DIR/repo/.git" ]]; then
        START_COMMIT=$(${pkgs.jq}/bin/jq -r '.start_commit // empty' "$SESSION_DIR/session.json" 2>/dev/null || true)
        if [[ -n "$START_COMMIT" ]]; then
          {
            echo "=== Git Log (since session start) ==="
            ${pkgs.git}/bin/git -C "$WS_DIR/repo" log --oneline "$START_COMMIT..HEAD" 2>/dev/null || echo "(no commits)"
            echo ""
            echo "=== Git Diff Stats (since session start) ==="
            ${pkgs.git}/bin/git -C "$WS_DIR/repo" diff --stat "$START_COMMIT" 2>/dev/null || echo "(no changes)"
          } > "$SESSION_DIR/git-summary.txt"
          echo "==> Captured git activity"
        fi
      fi

      # Export container journal
      if systemctl is-active --quiet "container@$CONTAINER" 2>/dev/null; then
        journalctl -M "$CONTAINER" --no-pager > "$SESSION_DIR/journal.log" 2>/dev/null || true
        echo "==> Exported container journal"
      fi

      # Copy Claude session data if present
      if [[ -d "$WS_DIR/repo/.claude" ]]; then
        cp -r "$WS_DIR/repo/.claude" "$SESSION_DIR/claude-data" 2>/dev/null || true
        echo "==> Copied Claude session data"
      fi

      # Update session metadata with end time
      END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      START_TIME=$(${pkgs.jq}/bin/jq -r '.start_time' "$SESSION_DIR/session.json" 2>/dev/null || echo "")
      if [[ -n "$START_TIME" ]]; then
        START_EPOCH=$(date -d "$START_TIME" +%s 2>/dev/null || echo "0")
        END_EPOCH=$(date -d "$END_TIME" +%s 2>/dev/null || echo "0")
        DURATION=$((END_EPOCH - START_EPOCH))
      else
        DURATION=0
      fi

      ${pkgs.jq}/bin/jq \
        --arg end_time "$END_TIME" \
        --argjson duration "$DURATION" \
        '. + {end_time: $end_time, duration_seconds: $duration}' \
        "$SESSION_DIR/session.json" > "$SESSION_DIR/session.json.tmp"
      mv "$SESSION_DIR/session.json.tmp" "$SESSION_DIR/session.json"
      echo "==> Updated session metadata"
    fi

    # Stop container
    echo "==> Stopping container $CONTAINER..."
    sudo nixos-container stop "$CONTAINER" 2>/dev/null || true

    # Clean up worktree from bare repo
    if [[ -n "$SESSION_ID" && -f "$SESSIONS_DIR/$SESSION_ID/session.json" ]]; then
      REPO_ORG=$(${pkgs.jq}/bin/jq -r '.org // "schemalabz"' "$SESSIONS_DIR/$SESSION_ID/session.json" 2>/dev/null || true)
      REPO_NAME=$(${pkgs.jq}/bin/jq -r '.repo // empty' "$SESSIONS_DIR/$SESSION_ID/session.json" 2>/dev/null || true)
      WT_BRANCH=$(${pkgs.jq}/bin/jq -r '.worktree_branch // empty' "$SESSIONS_DIR/$SESSION_ID/session.json" 2>/dev/null || true)
      BARE_DIR="$BASE_DIR/repos/$REPO_ORG/$REPO_NAME.git"
      if [[ -n "$REPO_NAME" && -d "$BARE_DIR" ]]; then
        ${pkgs.git}/bin/git -C "$BARE_DIR" worktree remove "$WS_DIR/repo" --force 2>/dev/null || true
        ${pkgs.git}/bin/git -C "$BARE_DIR" worktree prune 2>/dev/null || true
        # Delete the worktree branch
        if [[ -n "$WT_BRANCH" ]]; then
          ${pkgs.git}/bin/git -C "$BARE_DIR" branch -D "$WT_BRANCH" 2>/dev/null || true
        fi
        echo "==> Cleaned up worktree"
      fi
    fi

    # Clean workspace directory
    rm -rf "$WS_DIR"
    echo "==> Cleaned workspace directory"

    echo ""
    echo "==> Workspace slot $SLOT destroyed"
    if [[ -n "$SESSION_ID" ]]; then
      echo "    Session $SESSION_ID archived in $SESSIONS_DIR/$SESSION_ID/"
    fi
  '';

  workspaceList = pkgs.writeShellScriptBin "workspace-list" ''
    set -euo pipefail

    BASE_DIR="${cfg.workspacesDir}"
    SESSIONS_DIR="${cfg.sessionsDir}"

    printf "%-6s %-10s %-25s %-15s %-15s %-6s\n" "SLOT" "STATUS" "REPO" "BRANCH" "USER" "PORT"
    printf "%-6s %-10s %-25s %-15s %-15s %-6s\n" "----" "------" "----" "------" "----" "----"

    for n in ${concatMapStringsSep " " toString slotNumbers}; do
      CONTAINER="workspace-$n"
      SSH_PORT=$((${toString cfg.baseSSHPort} + n))
      WS_DIR="$BASE_DIR/ws-$n"

      STATE=$(systemctl show -p ActiveState --value "container@$CONTAINER" 2>/dev/null || echo "unknown")

      if [[ "$STATE" == "active" && -f "$WS_DIR/.session-id" ]]; then
        SESSION_ID=$(cat "$WS_DIR/.session-id")
        SESSION_FILE="$SESSIONS_DIR/$SESSION_ID/session.json"
        if [[ -f "$SESSION_FILE" ]]; then
          REPO=$(${pkgs.jq}/bin/jq -r '.repo // "-"' "$SESSION_FILE")
          BRANCH=$(${pkgs.jq}/bin/jq -r '.branch // "-"' "$SESSION_FILE")
          USER=$(${pkgs.jq}/bin/jq -r '.github_user // "-"' "$SESSION_FILE")
        else
          REPO="-"
          BRANCH="-"
          USER="-"
        fi
        printf "%-6s %-10s %-25s %-15s %-15s %-6s\n" "$n" "active" "$REPO" "$BRANCH" "$USER" "$SSH_PORT"
      else
        printf "%-6s %-10s %-25s %-15s %-15s %-6s\n" "$n" "available" "-" "-" "-" "$SSH_PORT"
      fi
    done
  '';

  workspaceSsh = pkgs.writeShellScriptBin "workspace-ssh" ''
    set -euo pipefail

    if [[ $# -ne 1 ]]; then
      echo "Usage: workspace-ssh <slot>"
      exit 1
    fi

    SLOT="$1"
    SSH_PORT=$((${toString cfg.baseSSHPort} + SLOT))

    exec ${pkgs.openssh}/bin/ssh \
      -p "$SSH_PORT" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      dev@127.0.0.1
  '';

  workspaceSessions = pkgs.writeShellScriptBin "workspace-sessions" ''
    set -euo pipefail

    SESSIONS_DIR="${cfg.sessionsDir}"
    LAST=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --last) LAST="$2"; shift 2 ;;
        *) echo "Usage: workspace-sessions [--last N]"; exit 1 ;;
      esac
    done

    if [[ ! -d "$SESSIONS_DIR" ]]; then
      echo "No sessions found"
      exit 0
    fi

    printf "%-20s %-25s %-15s %-15s %-12s %-20s\n" "SESSION" "REPO" "BRANCH" "USER" "DURATION" "DATE"
    printf "%-20s %-25s %-15s %-15s %-12s %-20s\n" "-------" "----" "------" "----" "--------" "----"

    # List session dirs sorted by name (contains timestamp), newest first
    DIRS=$(ls -1dr "$SESSIONS_DIR"/*/ 2>/dev/null || true)

    if [[ -n "$LAST" ]]; then
      DIRS=$(echo "$DIRS" | head -n "$LAST")
    fi

    for dir in $DIRS; do
      SESSION_FILE="$dir/session.json"
      if [[ -f "$SESSION_FILE" ]]; then
        ID=$(${pkgs.jq}/bin/jq -r '.id // "-"' "$SESSION_FILE")
        REPO=$(${pkgs.jq}/bin/jq -r '.repo // "-"' "$SESSION_FILE")
        BRANCH=$(${pkgs.jq}/bin/jq -r '.branch // "-"' "$SESSION_FILE")
        USER=$(${pkgs.jq}/bin/jq -r '.github_user // "-"' "$SESSION_FILE")
        START=$(${pkgs.jq}/bin/jq -r '.start_time // "-"' "$SESSION_FILE")
        DURATION_S=$(${pkgs.jq}/bin/jq -r '.duration_seconds // empty' "$SESSION_FILE" 2>/dev/null || echo "")

        if [[ -n "$DURATION_S" && "$DURATION_S" != "null" ]]; then
          HOURS=$((DURATION_S / 3600))
          MINS=$(( (DURATION_S % 3600) / 60 ))
          if [[ $HOURS -gt 0 ]]; then
            DURATION="''${HOURS}h ''${MINS}m"
          else
            DURATION="''${MINS}m"
          fi
        else
          DURATION="running"
        fi

        # Extract date from start_time
        DATE=$(echo "$START" | cut -dT -f1)

        printf "%-20s %-25s %-15s %-15s %-12s %-20s\n" "$ID" "$REPO" "$BRANCH" "$USER" "$DURATION" "$DATE"
      fi
    done
  '';

  workspaceRun = pkgs.writeShellScriptBin "workspace-run" ''
    set -euo pipefail

    SLOT=""
    PROMPT=""
    MAX_TURNS=""
    MAX_BUDGET=""
    RESUME=""
    ALLOWED_TOOLS=""
    WAIT=false

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --slot) SLOT="$2"; shift 2 ;;
        --prompt) PROMPT="$2"; shift 2 ;;
        --max-turns) MAX_TURNS="$2"; shift 2 ;;
        --max-budget) MAX_BUDGET="$2"; shift 2 ;;
        --resume) RESUME="$2"; shift 2 ;;
        --allowed-tools) ALLOWED_TOOLS="$2"; shift 2 ;;
        --wait) WAIT=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
      esac
    done

    if [[ -z "$SLOT" || -z "$PROMPT" ]]; then
      echo "Usage: workspace-run --slot <N> --prompt <text> [options]"
      echo ""
      echo "  --slot           Workspace slot number"
      echo "  --prompt         Prompt text to send to Claude"
      echo "  --max-turns      Maximum agentic turns (default: unlimited)"
      echo "  --max-budget     Maximum cost in USD (e.g., 5.00)"
      echo "  --resume         Resume a previous Claude session by ID"
      echo "  --allowed-tools  Comma-separated list of allowed tools"
      echo "  --wait           Wait for completion, extract Claude session ID"
      exit 1
    fi

    CONTAINER="workspace-$SLOT"
    BASE_DIR="${cfg.workspacesDir}"
    WS_DIR="$BASE_DIR/ws-$SLOT"
    SESSIONS_DIR="${cfg.sessionsDir}"

    # Verify container is running
    if ! systemctl is-active --quiet "container@$CONTAINER" 2>/dev/null; then
      echo "Error: Container $CONTAINER is not running"
      echo "Create a workspace first with: workspace-create --repo <name> --github-user <user>"
      exit 1
    fi

    # Get session info
    if [[ ! -f "$WS_DIR/.session-id" ]]; then
      echo "Error: No session found for slot $SLOT"
      exit 1
    fi
    SESSION_ID=$(cat "$WS_DIR/.session-id")
    SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"

    # Copy env file into workspace dir (bind-mounted, visible inside container)
    ENV_FILE="${cfg.envFile}"
    if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
      echo "Error: Env file not found at $ENV_FILE"
      echo "Create it with at least ANTHROPIC_API_KEY (GITHUB_TOKEN is optional if githubApp is enabled):"
      echo "  echo 'ANTHROPIC_API_KEY=sk-...' > $ENV_FILE"
      exit 1
    fi

    # Validate key is present
    if ! grep -q 'ANTHROPIC_API_KEY' "$ENV_FILE"; then
      echo "Error: ANTHROPIC_API_KEY not found in $ENV_FILE"
      exit 1
    fi

    # Write env and prompt files via the container — after workspace-setup
    # runs, the ws dir is owned by uid 1000 (dev), so the host user can't
    # write there directly. Piping through nixos-container run uses the
    # container's root to place the files.
    cat "$ENV_FILE" | sudo nixos-container run "$CONTAINER" -- \
      /run/current-system/sw/bin/bash -c "cat > '$WS_DIR/.env' && chown 1000:100 '$WS_DIR/.env' && chmod 600 '$WS_DIR/.env'"

    # Write prompt to a file (avoids quoting issues across shell boundaries)
    echo "$PROMPT" | sudo nixos-container run "$CONTAINER" -- \
      /run/current-system/sw/bin/bash -c "cat > '$WS_DIR/.prompt.txt' && chown 1000:100 '$WS_DIR/.prompt.txt'"

    # Build claude command
    CLAUDE_ARGS="-p --verbose --output-format stream-json --dangerously-skip-permissions"

    if [[ -n "$MAX_TURNS" ]]; then
      CLAUDE_ARGS="$CLAUDE_ARGS --max-turns $MAX_TURNS"
    fi
    if [[ -n "$MAX_BUDGET" ]]; then
      CLAUDE_ARGS="$CLAUDE_ARGS --max-budget-usd $MAX_BUDGET"
    fi
    if [[ -n "$RESUME" ]]; then
      CLAUDE_ARGS="$CLAUDE_ARGS --resume $RESUME"
    fi
    if [[ -n "$ALLOWED_TOOLS" ]]; then
      CLAUDE_ARGS="$CLAUDE_ARGS --allowedTools $ALLOWED_TOOLS"
    fi

    # Prepare log file
    RUN_ID="run-$(date -u +%Y%m%dT%H%M%S)"
    LOG_FILE="$SESSION_DIR/$RUN_ID.jsonl"
    PID_FILE="$SESSION_DIR/$RUN_ID.pid"

    echo "==> Starting Claude agent in workspace slot $SLOT..."
    echo "    Session:  $SESSION_ID"
    echo "    Run:      $RUN_ID"
    echo "    Log:      $LOG_FILE"

    # Build the inner script that runs inside the container as dev
    INNER_SCRIPT="set -a; source $WS_DIR/.env; set +a; cd $WS_DIR/repo && claude $CLAUDE_ARGS \"\$(cat $WS_DIR/.prompt.txt)\""

    # Helper to extract Claude session ID and result from completed log
    extract_session_info() {
      local log="$1"
      local session_dir="$2"
      if [[ -f "$log" ]]; then
        # Extract Claude session ID from init event
        CLAUDE_SESSION=$(${pkgs.jq}/bin/jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$log" 2>/dev/null | head -1)
        # Extract final result text
        RESULT_TEXT=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .result // empty' "$log" 2>/dev/null | head -1)
        # Extract cost, turns, duration
        COST=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .total_cost_usd // empty' "$log" 2>/dev/null | head -1)
        TURNS=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .num_turns // empty' "$log" 2>/dev/null | head -1)
        DURATION_MS=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .duration_ms // empty' "$log" 2>/dev/null | head -1)

        # Update session metadata with claude session ID and run stats
        if [[ -n "$CLAUDE_SESSION" ]]; then
          ${pkgs.jq}/bin/jq \
            --arg claude_session_id "$CLAUDE_SESSION" \
            --arg result "''${RESULT_TEXT:0:1000}" \
            --arg cost "''${COST:-unknown}" \
            --arg turns "''${TURNS:-unknown}" \
            --arg duration_ms "''${DURATION_MS:-unknown}" \
            '.active_run += {claude_session_id: $claude_session_id, result: $result, cost: $cost, turns: $turns, duration_ms: $duration_ms}' \
            "$session_dir/session.json" > "$session_dir/session.json.tmp"
          mv "$session_dir/session.json.tmp" "$session_dir/session.json"
        fi
      fi
    }

    if $WAIT; then
      # Foreground mode — wait for completion, extract session info
      echo "==> Running (waiting for completion)..."
      sudo nixos-container run "$CONTAINER" -- \
        /run/current-system/sw/bin/bash -c "runuser -l dev -c '$INNER_SCRIPT'" \
        > "$LOG_FILE" 2>&1
      EXIT_CODE=$?

      # Update session metadata
      ${pkgs.jq}/bin/jq \
        --arg run_id "$RUN_ID" \
        --arg log_file "$LOG_FILE" \
        --arg prompt "$PROMPT" \
        '. + {active_run: {run_id: $run_id, log_file: $log_file, prompt: $prompt}}' \
        "$SESSION_DIR/session.json" > "$SESSION_DIR/session.json.tmp"
      mv "$SESSION_DIR/session.json.tmp" "$SESSION_DIR/session.json"

      # Extract Claude session ID and result
      extract_session_info "$LOG_FILE" "$SESSION_DIR"

      # Read back the claude session ID for output
      CLAUDE_SESSION=$(${pkgs.jq}/bin/jq -r '.active_run.claude_session_id // empty' "$SESSION_DIR/session.json" 2>/dev/null)
      RESULT_TEXT=$(${pkgs.jq}/bin/jq -r '.active_run.result // empty' "$SESSION_DIR/session.json" 2>/dev/null)
      RUN_COST=$(${pkgs.jq}/bin/jq -r '.active_run.cost // empty' "$SESSION_DIR/session.json" 2>/dev/null)

      # Extract turns and duration directly from log
      RUN_TURNS=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .num_turns // empty' "$LOG_FILE" 2>/dev/null | head -1)
      RUN_DURATION_MS=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .duration_ms // empty' "$LOG_FILE" 2>/dev/null | head -1)

      echo ""
      echo "==> Run complete"
      echo "    Run:              $RUN_ID"
      echo "    Claude session:   ''${CLAUDE_SESSION:-(not found)}"
      echo "    Log:              $LOG_FILE"
      if [[ -n "$RUN_COST" && "$RUN_COST" != "unknown" ]]; then
        echo "    Cost:             \$$RUN_COST"
      fi
      if [[ -n "$RUN_TURNS" ]]; then
        echo "    Turns:            $RUN_TURNS"
      fi
      if [[ -n "$RUN_DURATION_MS" ]]; then
        DURATION_SEC=$((RUN_DURATION_MS / 1000))
        DURATION_MIN=$((DURATION_SEC / 60))
        DURATION_REM=$((DURATION_SEC % 60))
        echo "    Duration:         ''${DURATION_MIN}m ''${DURATION_REM}s"
      fi
      if [[ -n "$RESULT_TEXT" ]]; then
        echo ""
        echo "=== Result ==="
        echo "$RESULT_TEXT"
      fi
    else
      # Background mode — launch and return immediately
      sudo nixos-container run "$CONTAINER" -- \
        /run/current-system/sw/bin/bash -c "runuser -l dev -c '$INNER_SCRIPT'" \
        > "$LOG_FILE" 2>&1 &
      AGENT_PID=$!
      echo "$AGENT_PID" > "$PID_FILE"

      # Update session metadata with agent run info
      ${pkgs.jq}/bin/jq \
        --arg run_id "$RUN_ID" \
        --argjson agent_pid "$AGENT_PID" \
        --arg log_file "$LOG_FILE" \
        --arg prompt "$PROMPT" \
        '. + {active_run: {run_id: $run_id, agent_pid: $agent_pid, log_file: $log_file, prompt: $prompt}}' \
        "$SESSION_DIR/session.json" > "$SESSION_DIR/session.json.tmp"
      mv "$SESSION_DIR/session.json.tmp" "$SESSION_DIR/session.json"

      echo "    PID:      $AGENT_PID"
      echo ""
      echo "==> Agent running in background"
      echo "    Monitor with: workspace-status --slot $SLOT"
      echo "    Full log:     workspace-status --slot $SLOT --full"
    fi
  '';

  workspaceStatus = pkgs.writeShellScriptBin "workspace-status" ''
    set -euo pipefail

    SLOT=""
    FULL=false
    TAIL_LINES=30
    FOLLOW=false

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --slot) SLOT="$2"; shift 2 ;;
        --full) FULL=true; shift ;;
        --tail) TAIL_LINES="$2"; shift 2 ;;
        --follow|-f) FOLLOW=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
      esac
    done

    if [[ -z "$SLOT" ]]; then
      echo "Usage: workspace-status --slot <N> [options]"
      echo ""
      echo "  --slot       Workspace slot number"
      echo "  --tail N     Show last N lines of output (default: 30)"
      echo "  --full       Show full log with extracted messages"
      echo "  --follow/-f  Follow log output in real-time"
      exit 1
    fi

    BASE_DIR="${cfg.workspacesDir}"
    WS_DIR="$BASE_DIR/ws-$SLOT"
    SESSIONS_DIR="${cfg.sessionsDir}"

    if [[ ! -f "$WS_DIR/.session-id" ]]; then
      echo "Error: No session found for slot $SLOT"
      exit 1
    fi
    SESSION_ID=$(cat "$WS_DIR/.session-id")
    SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"

    # Get active run info from session metadata
    RUN_ID=$(${pkgs.jq}/bin/jq -r '.active_run.run_id // empty' "$SESSION_DIR/session.json" 2>/dev/null || true)
    AGENT_PID=$(${pkgs.jq}/bin/jq -r '.active_run.agent_pid // empty' "$SESSION_DIR/session.json" 2>/dev/null || true)
    LOG_FILE=$(${pkgs.jq}/bin/jq -r '.active_run.log_file // empty' "$SESSION_DIR/session.json" 2>/dev/null || true)

    if [[ -z "$RUN_ID" ]]; then
      echo "No agent run found for slot $SLOT"
      echo "Start one with: workspace-run --slot $SLOT --prompt '<task>'"
      exit 1
    fi

    # Check if agent process is alive
    ALIVE=false
    if [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null; then
      ALIVE=true
    fi

    # Read Claude session ID if already extracted
    CLAUDE_SESSION=$(${pkgs.jq}/bin/jq -r '.active_run.claude_session_id // empty' "$SESSION_DIR/session.json" 2>/dev/null || true)

    # If stopped and no claude_session_id yet, extract it from the log
    if ! $ALIVE && [[ -z "$CLAUDE_SESSION" && -f "$LOG_FILE" ]]; then
      CLAUDE_SESSION=$(${pkgs.jq}/bin/jq -r 'select(.type == "system" and .subtype == "init") | .session_id' "$LOG_FILE" 2>/dev/null | head -1 || true)
      COST=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .total_cost_usd // empty' "$LOG_FILE" 2>/dev/null | head -1 || true)
      RESULT_TEXT=$(${pkgs.jq}/bin/jq -r 'select(.type == "result") | .result // empty' "$LOG_FILE" 2>/dev/null | head -1 || true)
      if [[ -n "$CLAUDE_SESSION" ]]; then
        ${pkgs.jq}/bin/jq \
          --arg claude_session_id "$CLAUDE_SESSION" \
          --arg result "''${RESULT_TEXT:0:1000}" \
          --arg cost "''${COST:-unknown}" \
          '.active_run += {claude_session_id: $claude_session_id, result: $result, cost: $cost}' \
          "$SESSION_DIR/session.json" > "$SESSION_DIR/session.json.tmp"
        mv "$SESSION_DIR/session.json.tmp" "$SESSION_DIR/session.json"
      fi
    fi

    echo "=== Agent Status ==="
    echo "  Session:   $SESSION_ID"
    echo "  Run:       $RUN_ID"
    if [[ -n "$AGENT_PID" ]]; then
      echo "  PID:       $AGENT_PID"
    fi
    if [[ -n "$CLAUDE_SESSION" ]]; then
      echo "  Claude:    $CLAUDE_SESSION"
    fi
    if $ALIVE; then
      echo "  Status:    RUNNING"
    else
      echo "  Status:    STOPPED"
    fi

    if [[ ! -f "$LOG_FILE" ]]; then
      echo ""
      echo "(no log file found)"
      exit 0
    fi

    LOG_SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")
    LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    echo "  Log:       $LOG_FILE ($LOG_LINES lines, $(( LOG_SIZE / 1024 ))KB)"

    # Follow mode — just tail -f the log
    if $FOLLOW; then
      echo ""
      echo "=== Following log (Ctrl+C to stop) ==="
      tail -f "$LOG_FILE" | while IFS= read -r line; do
        # Try to extract readable content from stream-json
        TYPE=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.type // empty' 2>/dev/null || true)
        case "$TYPE" in
          assistant)
            MSG=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null || true)
            if [[ -n "$MSG" ]]; then
              echo "[assistant] $MSG"
            fi
            ;;
          result)
            COST=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.total_cost_usd // "?"' 2>/dev/null || true)
            TURNS=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.num_turns // "?"' 2>/dev/null || true)
            echo "[result] Done — cost: \$$COST, turns: $TURNS"
            ;;
          *)
            # Show tool use and other events briefly
            if [[ -n "$TYPE" ]]; then
              echo "[$TYPE]"
            fi
            ;;
        esac
      done
      exit 0
    fi

    echo ""

    if $FULL; then
      echo "=== Agent Messages ==="
      # Extract assistant text messages and results from stream-json
      while IFS= read -r line; do
        TYPE=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.type // empty' 2>/dev/null || true)
        case "$TYPE" in
          "system/init")
            SID=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.session_id // "?"' 2>/dev/null || true)
            echo "[init] Claude session: $SID"
            ;;
          assistant)
            # Extract text content
            MSG=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null || true)
            if [[ -n "$MSG" ]]; then
              echo ""
              echo "[assistant] $MSG"
            fi
            # Extract tool use names
            TOOLS=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.message.content[]? | select(.type == "tool_use") | .name' 2>/dev/null || true)
            if [[ -n "$TOOLS" ]]; then
              echo "[tool_use] $TOOLS"
            fi
            ;;
          result)
            COST=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.total_cost_usd // "?"' 2>/dev/null || true)
            TURNS=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.num_turns // "?"' 2>/dev/null || true)
            DURATION=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.duration_ms // "?"' 2>/dev/null || true)
            echo ""
            echo "[result] Done — cost: \$$COST, turns: $TURNS, duration: ''${DURATION}ms"
            RESULT_TEXT=$(echo "$line" | ${pkgs.jq}/bin/jq -r '.result // empty' 2>/dev/null || true)
            if [[ -n "$RESULT_TEXT" ]]; then
              echo "[result] $RESULT_TEXT"
            fi
            ;;
        esac
      done < "$LOG_FILE"
    else
      echo "=== Log (last $TAIL_LINES lines) ==="
      tail -n "$TAIL_LINES" "$LOG_FILE"
    fi
  '';

  workspaceSession = pkgs.writeShellScriptBin "workspace-session" ''
    set -euo pipefail

    if [[ $# -ne 1 ]]; then
      echo "Usage: workspace-session <session-id>"
      exit 1
    fi

    SESSION_ID="$1"
    SESSIONS_DIR="${cfg.sessionsDir}"
    SESSION_DIR="$SESSIONS_DIR/$SESSION_ID"

    if [[ ! -d "$SESSION_DIR" ]]; then
      echo "Error: Session '$SESSION_ID' not found"
      exit 1
    fi

    echo "=== Session Metadata ==="
    if [[ -f "$SESSION_DIR/session.json" ]]; then
      ${pkgs.jq}/bin/jq '.' "$SESSION_DIR/session.json"
    else
      echo "(no metadata)"
    fi

    echo ""
    echo "=== Git Activity ==="
    if [[ -f "$SESSION_DIR/git-summary.txt" ]]; then
      cat "$SESSION_DIR/git-summary.txt"
    else
      echo "(no git summary — session may still be active)"
    fi

    echo ""
    echo "=== Journal (last 50 lines) ==="
    if [[ -f "$SESSION_DIR/journal.log" ]]; then
      tail -n 50 "$SESSION_DIR/journal.log"
    else
      echo "(no journal export — session may still be active)"
    fi

    if [[ -d "$SESSION_DIR/claude-data" ]]; then
      echo ""
      echo "=== Claude Data ==="
      echo "Claude session data available at: $SESSION_DIR/claude-data/"
      ls -la "$SESSION_DIR/claude-data/" 2>/dev/null || true
    fi
  '';

in {
  options.services.dev-workspaces = {
    enable = mkEnableOption "ephemeral dev workspaces via NixOS containers";

    slots = mkOption {
      type = types.int;
      default = 4;
      description = "Number of pre-declared workspace container slots.";
    };

    baseSSHPort = mkOption {
      type = types.int;
      default = 2200;
      description = "Base SSH port. Slot N gets port baseSSHPort+N (e.g., 2201-2204).";
    };

    workspacesDir = mkOption {
      type = types.path;
      default = "/var/lib/workspaces";
      description = "Base directory for workspace bind mounts.";
    };

    sessionsDir = mkOption {
      type = types.path;
      default = "/var/lib/workspaces/sessions";
      description = "Directory for session archives.";
    };

    envFile = mkOption {
      type = types.nullOr types.path;
      default = "/var/lib/workspaces/.env";
      description = ''
        Path to env file with secrets for workspace agents.
        Must contain ANTHROPIC_API_KEY. GITHUB_TOKEN is optional when
        githubApp is enabled (tokens are managed automatically).
        Sourced by workspace-run before launching Claude.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = "User that owns workspace directories and manages workspaces.";
    };

    group = mkOption {
      type = types.str;
      default = "root";
      description = "Group that owns workspace directories.";
    };

    networkSubnet = mkOption {
      type = types.str;
      default = "10.233";
      description = "First two octets of the container subnet (e.g., 10.233).";
    };

    defaultPackages = mkOption {
      type = types.listOf types.package;
      default = with pkgs; [
        git
        gh
        nodejs
        curl
        vim
        nano
        jq
        htop
        nix
        claude-code
      ];
      description = "Packages available inside workspace containers.";
    };
  };

  config = mkIf cfg.enable {
    # Ensure base directories exist, owned by the configured user
    systemd.tmpfiles.rules = [
      "d ${cfg.workspacesDir} 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.workspacesDir}/repos 0755 ${cfg.user} ${cfg.group} -"
      "d ${cfg.sessionsDir} 0755 ${cfg.user} ${cfg.group} -"
    ] ++ map (n: "d ${cfg.workspacesDir}/ws-${toString n} 0755 ${cfg.user} ${cfg.group} -") slotNumbers;

    # Enable IP forwarding for container networking
    boot.kernel.sysctl."net.ipv4.ip_forward" = "1";

    # NAT for container internet access
    networking.nat = {
      enable = true;
      internalInterfaces = map (n: "ve-workspace-${toString n}") slotNumbers;
      forwardPorts = map (n: {
        sourcePort = cfg.baseSSHPort + n;
        destination = "${cfg.networkSubnet}.${toString n}.1:22";
        proto = "tcp";
      }) slotNumbers;
    };

    # Open SSH forwarding ports on firewall
    networking.firewall.allowedTCPPorts =
      map (n: cfg.baseSSHPort + n) slotNumbers;

    # Container declarations
    containers = listToAttrs (map (n:
      let
        name = containerName n;
        wsDir = "${cfg.workspacesDir}/ws-${toString n}";
      in {
        inherit name;
        value = {
          ephemeral = true;
          autoStart = false;
          privateNetwork = true;

          hostAddress = "${cfg.networkSubnet}.${toString n}.0";
          localAddress = "${cfg.networkSubnet}.${toString n}.1";

          bindMounts = {
            "/nix" = {
              hostPath = "/nix";
              isReadOnly = false;
            };
            "/nix/var/nix/daemon-socket" = {
              hostPath = "/nix/var/nix/daemon-socket";
              isReadOnly = false;
            };
            # Mount workspace at its real host path so worktree metadata
            # (absolute paths in .git files) resolves correctly inside container
            "${wsDir}" = {
              hostPath = wsDir;
              isReadOnly = false;
            };
            # Bare repos dir — worktree .git files reference absolute paths here
            "${cfg.workspacesDir}/repos" = {
              hostPath = "${cfg.workspacesDir}/repos";
              isReadOnly = false;
            };
          };

          config = { pkgs, ... }: {
            # Use host nix daemon — no separate daemon per container
            nix.enable = false;

            system.stateVersion = "24.11";
            networking.firewall.enable = false;

            environment.systemPackages = cfg.defaultPackages;

            # Nix CLI config (flakes, trust dev user via host daemon)
            environment.etc."nix/nix.conf".text = ''
              experimental-features = nix-command flakes
            '';

            # SSH server for remote access
            services.openssh = {
              enable = true;
              settings = {
                PasswordAuthentication = false;
                PermitRootLogin = "no";
              };
            };

            # Dev user with sudo access
            users.users.dev = {
              isNormalUser = true;
              home = "/home/dev";
              extraGroups = [ "wheel" ];
              shell = pkgs.bash;
            };

            security.sudo.wheelNeedsPassword = false;

            # Workspace setup on container start
            systemd.services.workspace-setup = {
              description = "Workspace environment setup";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };
              script = let ws = "${wsDir}"; in ''
                set -euo pipefail

                # Set up SSH keys for dev user
                mkdir -p /home/dev/.ssh
                if [[ -f ${ws}/.ssh/authorized_keys ]]; then
                  cp ${ws}/.ssh/authorized_keys /home/dev/.ssh/authorized_keys
                  chmod 700 /home/dev/.ssh
                  chmod 600 /home/dev/.ssh/authorized_keys
                  chown -R dev:users /home/dev/.ssh
                fi

                # Symlink repo into dev home
                ln -sfn ${ws}/repo /home/dev/repo

                # Set ownership of workspace.
                # Keep group-writable so the host user (openclaw) can still
                # write/delete files via the shared 'users' group (gid 100).
                chown -R dev:users ${ws} 2>/dev/null || true
                chmod -R g+w ${ws} 2>/dev/null || true

                # Git safe.directory — worktree + bare repo may have mixed ownership
                mkdir -p /home/dev/.config/git
                echo '[safe]' > /home/dev/.config/git/config
                echo '    directory = *' >> /home/dev/.config/git/config
                chown -R dev:users /home/dev/.config
              '';
            };
          };
        };
      }
    ) slotNumbers);

    # Memory limits per container
    systemd.services = listToAttrs (map (n: {
      name = "container@${containerName n}";
      value = {
        serviceConfig.MemoryMax = "1G";
      };
    }) slotNumbers);

    # Management scripts
    environment.systemPackages = [
      workspaceCreate
      workspaceDestroy
      workspaceList
      workspaceSsh
      workspaceSessions
      workspaceSession
      workspaceRun
      workspaceStatus
    ];

    # Allow the workspace user to manage containers without a password
    # Allow the workspace user to manage only workspace containers.
    # Each slot gets explicit rules — no wildcards on nixos-container
    # to avoid granting access to unrelated containers.
    security.sudo.extraRules = mkIf (cfg.user != "root") [
      {
        users = [ cfg.user ];
        commands = concatMap (n:
          let name = containerName n; in [
            {
              command = "/run/current-system/sw/bin/nixos-container start ${name}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "/run/current-system/sw/bin/nixos-container stop ${name}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "/run/current-system/sw/bin/nixos-container run ${name} -- *";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${pkgs.systemd}/bin/systemctl start container@${name}";
              options = [ "NOPASSWD" ];
            }
            {
              command = "${pkgs.systemd}/bin/systemctl stop container@${name}";
              options = [ "NOPASSWD" ];
            }
          ]
        ) slotNumbers;
      }
    ];
  };
}
