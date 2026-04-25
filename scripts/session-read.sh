#!/usr/bin/env bash
# session-read — read OpenClaw agent conversation sessions.
#
# A standalone tool for reading OpenClaw gateway session logs stored as JSONL.
# Works with any OpenClaw installation — auto-detects the data directory or
# accepts an explicit path.
#
# Usage:
#   session-read --list                              List all sessions
#   session-read --latest [--tail N] [--verbose]     Read most recent session
#   session-read <uuid> [--tail N] [--verbose]       Read specific session
#   session-read --channel <name> [--tail N]         Read by channel name match
#
# Options:
#   --tail N       Show only the last N conversational turns
#   --verbose      Show all tool results, not just errors
#   --data-dir     OpenClaw data directory (auto-detected if omitted)
#   --agent        Agent name (default: main)
#
# Environment:
#   OPENCLAW_DATA_DIR    Override the data directory
#   OPENCLAW_AGENT       Override the agent name (default: main)
#
# Session directory layout (from OpenClaw gateway):
#   <dataDir>/state/agents/<agent>/sessions/
#     sessions.json          Index mapping channel keys → session files
#     <uuid>.jsonl           Session event log (one JSON object per line)
#
# Requires: jq, bash 4+

set -euo pipefail

# --- configuration ---

# Auto-detect OpenClaw data directory.
# Checks common locations, then falls back to env var or explicit flag.
detect_data_dir() {
  local candidates=(
    "$HOME/.openclaw"
    "/var/lib/openclaw-agent"
    "/var/lib/opencouncil-discord-bot"
  )
  for dir in "${candidates[@]}"; do
    if [[ -d "$dir/state/agents" ]]; then
      echo "$dir"
      return
    fi
  done
  return 1
}

DATA_DIR="${OPENCLAW_DATA_DIR:-}"
AGENT="${OPENCLAW_AGENT:-main}"

resolve_sessions_dir() {
  if [[ -z "$DATA_DIR" ]]; then
    DATA_DIR=$(detect_data_dir) || die "Could not auto-detect OpenClaw data directory. Use --data-dir or set OPENCLAW_DATA_DIR."
  fi
  echo "$DATA_DIR/state/agents/$AGENT/sessions"
}

# --- helpers ---

die() { echo "Error: $*" >&2; exit 1; }

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required but not found in PATH"
}

# Extract the source type from a session key
# e.g. "discord" from "agent:main:discord:channel:123"
# e.g. "webhook" from "agent:main:webhook:endpoint:abc"
source_from_key() {
  echo "$1" | awk -F: '{print $3}'
}

# Extract a human-readable channel label from the first user message.
# Looks for conversation_label in the OpenClaw metadata block that the
# gateway prepends to user messages.
channel_label_from_file() {
  local file="$1"
  jq -r '
    select(.type == "message" and .message.role == "user")
    | .message.content[]?
    | select(.type == "text")
    | .text
    | capture("\"conversation_label\":\\s*\"(?<label>[^\"]+)\"")
    | .label
  ' "$file" 2>/dev/null | head -1
}

# --- commands ---

cmd_list() {
  local sessions_dir="$1"
  local index="$sessions_dir/sessions.json"

  [[ -f "$index" ]] || die "No sessions index at $index"

  printf "%-38s %-10s %-45s %-22s %s\n" "SESSION" "SOURCE" "CHANNEL" "LAST ACTIVITY" "MSGS"
  printf "%-38s %-10s %-45s %-22s %s\n" "-------" "------" "-------" "-------------" "----"

  jq -r 'to_entries[] | "\(.key)\t\(.value.sessionFile)"' "$index" | while IFS=$'\t' read -r key file; do
    [[ -f "$file" ]] || continue

    uuid=$(basename "$file" .jsonl)
    source=$(source_from_key "$key")

    label=$(channel_label_from_file "$file")
    [[ -z "$label" ]] && label="-"

    last_mod=$(stat -c '%Y' "$file" 2>/dev/null || echo "0")
    last_activity=$(date -d "@$last_mod" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-")

    msg_count=$(jq -c 'select(.type == "message" and (.message.role == "user" or .message.role == "assistant"))' "$file" 2>/dev/null | wc -l)

    printf "%-38s %-10s %-45s %-22s %s\n" "$uuid" "$source" "${label:0:45}" "$last_activity" "$msg_count"
  done | sort -k4 -r
}

cmd_read() {
  local file="$1"
  local tail_n="${2:-0}"
  local verbose="${3:-false}"

  [[ -f "$file" ]] || die "Session file not found: $file"

  # Print session header
  local session_id start_ts model label
  session_id=$(jq -r 'select(.type == "session") | .id' "$file" | head -1)
  start_ts=$(jq -r 'select(.type == "session") | .timestamp' "$file" | head -1)
  model=$(jq -r 'select(.type == "model_change") | .modelId' "$file" | head -1)
  label=$(channel_label_from_file "$file")

  echo "═══════════════════════════════════════════════════════════"
  echo "  Session:  ${session_id:-unknown}"
  echo "  Started:  ${start_ts:-unknown}"
  echo "  Model:    ${model:-unknown}"
  [[ -n "$label" ]] && echo "  Channel:  $label"
  echo "═══════════════════════════════════════════════════════════"
  echo ""

  # Single jq pass over the file. The `inputs` function reads the rest of
  # the file after the first line, so we pass /dev/null as the first "file"
  # and the real file via inputs.
  jq -r --argjson tail_n "$tail_n" --argjson verbose "$verbose" '
    # Collect all message events
    [inputs | select(.type == "message")] as $msgs |

    # Apply tail filter: find the index of the Nth-from-last user message
    (if $tail_n > 0 then
      [$msgs | to_entries[] | select(.value.message.role == "user") | .key] |
      if length > $tail_n then .[-$tail_n] else 0 end
    else 0 end) as $start |

    $msgs[$start:][] |

    .message.role as $role |
    (.timestamp | split("T") | .[1] | split(".") | .[0]) as $time |

    if $role == "user" then
      (.message.content // [] | map(select(.type == "text") | .text) | join("\n")) as $raw |

      # Extract sender from metadata
      ($raw | capture("\"label\":\\s*\"(?<l>[^\"]+)\"") | .l // "user") as $sender |

      # Strip gateway metadata blocks, keep the actual user message.
      # "Replied message" is reformatted as a compact reply quote.
      ($raw
        | gsub("Conversation info[^\n]*\n```json\n[^`]*```\n?"; "")
        | gsub("Sender[^\n]*\n```json\n[^`]*```\n?"; "")
        | gsub("Chat history since last reply[^\n]*\n```json\n[^`]*```\n?"; "")
        | gsub("^System:[^\n]*\n?"; "")
        | gsub("Replied message[^\n]*\n```json\n\\{[^}]*\"body\":\\s*\"(?<body>[^\"]*)\"[^}]*\\}\n```\n?"; "  ↩ replying to: \(.body)\n")
        | gsub("^\\s+"; "") | gsub("\\s+$"; "")
      ) as $clean |

      if ($clean | length) > 0 then
        "┌─ \($sender) [\($time)]\n│ \($clean | gsub("\n"; "\n│ "))\n└─\n"
      else empty end

    elif $role == "assistant" then
      (.message.content // [] | map(select(.type == "text") | .text) | join("\n")) as $texts |
      [.message.content // [] | .[] | select(.type == "toolCall") | .name] as $tools |

      if ($texts | length) > 0 or ($tools | length) > 0 then
        "┌─ bot [\($time)]" +
        (if ($texts | length) > 0 then "\n│ \($texts | gsub("\n"; "\n│ "))" else "" end) +
        (if ($tools | length) > 0 then "\n│ ⚙ \($tools | join("\n│ ⚙ "))" else "" end) +
        "\n└─\n"
      else empty end

    elif $role == "toolResult" then
      (.message.content // "" |
        if type == "string" then .
        elif type == "array" then map(select(.type == "text") | .text) | join("\n")
        else "" end
      ) as $result |

      # Classify the result
      ($result | test("(?i)\"status\":\\s*\"error\"|EACCES|permission denied|fatal:|Access denied")) as $is_error |
      ($result | test("(?i)error|failed|denied|warning")) as $has_warning |

      if $is_error then
        "  ⚠ \($result | gsub("\n"; " ") | .[:200])\n"
      elif $verbose then
        "  → \($result | split("\n") | .[0:5] | join("\n    ") | .[:500])\n"
      elif $has_warning then
        "  ⚠ \($result | split("\n") | map(select(test("(?i)error|failed|denied|warning"))) | .[0:2] | join(" | ") | .[:150])\n"
      else empty end

    else empty end
  ' /dev/null "$file"
}

# --- resolvers ---

resolve_session() {
  local sessions_dir="$1" input="$2"

  # Full UUID
  if [[ "$input" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    echo "$sessions_dir/$input.jsonl"
    return
  fi

  # Partial UUID prefix
  local matches
  matches=$(find "$sessions_dir" -maxdepth 1 -name "${input}*.jsonl" -print 2>/dev/null | head -2)
  local count
  count=$(echo "$matches" | grep -c . 2>/dev/null || echo 0)
  if [[ "$count" -eq 1 ]]; then
    echo "$matches"
    return
  elif [[ "$count" -gt 1 ]]; then
    die "Ambiguous UUID prefix '$input' — matches multiple sessions"
  fi

  die "No session found for '$input'"
}

resolve_latest() {
  local sessions_dir="$1"
  find "$sessions_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2
}

resolve_channel() {
  local sessions_dir="$1" pattern="$2"
  local best_file="" best_mtime=0

  for file in "$sessions_dir"/*.jsonl; do
    [[ -f "$file" ]] || continue
    local label
    label=$(channel_label_from_file "$file")
    if echo "$label" | grep -qi "$pattern" 2>/dev/null; then
      local mtime
      mtime=$(stat -c '%Y' "$file" 2>/dev/null || echo "0")
      if [[ "$mtime" -gt "$best_mtime" ]]; then
        best_mtime="$mtime"
        best_file="$file"
      fi
    fi
  done

  [[ -n "$best_file" ]] || die "No session found matching channel '$pattern'"
  echo "$best_file"
}

# --- main ---

main() {
  need_jq

  local mode="" target="" tail_n=0 verbose=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list|-l) mode="list"; shift ;;
      --latest) mode="latest"; shift ;;
      --channel|-c) mode="channel"; target="$2"; shift 2 ;;
      --tail|-n) tail_n="$2"; shift 2 ;;
      --verbose|-v) verbose=true; shift ;;
      --data-dir|-d) DATA_DIR="$2"; shift 2 ;;
      --agent|-a) AGENT="$2"; shift 2 ;;
      --help|-h)
        cat <<'HELP'
session-read — read OpenClaw agent conversation sessions

Usage:
  session-read --list                    List all sessions
  session-read --latest [--tail N]       Read most recent session
  session-read <uuid> [--tail N]         Read specific session
  session-read --channel <name> [--tail N]  Read by channel name

Options:
  --tail N       Show only the last N conversational turns
  --verbose      Show all tool results, not just errors
  --data-dir     OpenClaw data directory (auto-detected if omitted)
  --agent        Agent name (default: main)

Environment:
  OPENCLAW_DATA_DIR    Override the data directory
  OPENCLAW_AGENT       Override the agent name (default: main)

The tool auto-detects the OpenClaw data directory by checking:
  ~/.openclaw, /var/lib/openclaw-agent, /var/lib/opencouncil-discord-bot
HELP
        exit 0
        ;;
      -*)
        die "Unknown option: $1 (try --help)"
        ;;
      *)
        if [[ -z "$mode" ]]; then
          mode="uuid"
          target="$1"
        fi
        shift
        ;;
    esac
  done

  local sessions_dir
  sessions_dir=$(resolve_sessions_dir)
  [[ -d "$sessions_dir" ]] || die "Sessions directory not found: $sessions_dir"

  [[ -n "$mode" ]] || mode="list"

  case "$mode" in
    list)
      cmd_list "$sessions_dir"
      ;;
    latest)
      local file
      file=$(resolve_latest "$sessions_dir")
      [[ -n "$file" ]] || die "No sessions found"
      cmd_read "$file" "$tail_n" "$verbose"
      ;;
    channel)
      local file
      file=$(resolve_channel "$sessions_dir" "$target")
      cmd_read "$file" "$tail_n" "$verbose"
      ;;
    uuid)
      local file
      file=$(resolve_session "$sessions_dir" "$target")
      cmd_read "$file" "$tail_n" "$verbose"
      ;;
  esac
}

main "$@"
