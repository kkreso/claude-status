#!/bin/bash
# Claude Status — Session status hook
#
# Writes a per-session status file to the Claude project directory
# so the Claude Status macOS menu bar app can read session state.
#
# No external dependencies — uses only bash builtins and standard macOS tools.
#
# Status file: ~/.claude/projects/<encoded-path>/<session_id>.cstatus
# Format:     {"session_id":"...","pid":N,"ppid":N,"state":"...","activity":"...","timestamp":"...","cwd":"...","event":"..."}
#
# States:
#   active     — Claude is processing a prompt or executing tools
#   waiting    — Claude is blocked waiting for user action (e.g. permission prompt)
#   idle       — Session just started or has no pending work
#   compacting — Session is compacting context

set -euo pipefail

# Read JSON input from stdin
INPUT=$(cat)

# Escape a string for safe interpolation into JSON string values.
# Handles backslash, double quote, and control characters.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

# Extract a string value from JSON using only sed (no jq dependency)
extract_json_string() {
    local key="$1"
    local json="$2"
    echo "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

EVENT=$(extract_json_string "hook_event_name" "$INPUT")
SESSION_ID=$(extract_json_string "session_id" "$INPUT")
TRANSCRIPT=$(extract_json_string "transcript_path" "$INPUT")
CWD=$(extract_json_string "cwd" "$INPUT")

# PPID is the Claude process that spawned this hook
CLAUDE_PID=$PPID

# Get the parent of the Claude process (the shell/IDE that launched it)
CLAUDE_PPID=$(ps -o ppid= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')
CLAUDE_PPID=${CLAUDE_PPID:-0}

# Derive the project directory from the transcript path
PROJECT_DIR=$(dirname "$TRANSCRIPT")

# Bail out if we can't determine the project directory
if [[ -z "$PROJECT_DIR" || "$PROJECT_DIR" == "." ]]; then
    exit 0
fi

STATUS_FILE="${PROJECT_DIR}/${SESSION_ID}.cstatus"

# On SessionEnd, remove the status file, notify, and exit
if [[ "$EVENT" == "SessionEnd" ]]; then
    rm -f "$STATUS_FILE"
    /usr/bin/notifyutil -p com.poisonpenllc.Claude-Status.session-changed 2>/dev/null || true
    exit 0
fi

# Extract tool_name for tool-related events
TOOL_NAME=$(extract_json_string "tool_name" "$INPUT")

# Read the previous state from the existing .cstatus file (if any).
# During compaction, tool-use hooks fire but should not override the
# "compacting" state — only definitive end events (Stop, UserPromptSubmit,
# SessionStart, SessionEnd) clear it.
PREV_STATE=""
if [[ -f "$STATUS_FILE" ]]; then
    PREV_STATE=$(extract_json_string "state" "$(cat "$STATUS_FILE")")
fi

# Map hook event to session state and activity
ACTIVITY=""
case "$EVENT" in
    SessionStart)
        STATUS="idle"
        ;;
    UserPromptSubmit)
        STATUS="active"
        ACTIVITY="thinking"
        ;;
    PreToolUse)
        STATUS="active"
        ACTIVITY="$TOOL_NAME"
        ;;
    PostToolUse)
        STATUS="active"
        ;;
    PostToolUseFailure)
        STATUS="active"
        ;;
    PermissionRequest)
        STATUS="waiting"
        ACTIVITY="$TOOL_NAME"
        ;;
    PreCompact)
        STATUS="compacting"
        COMPACT_TRIGGER=$(extract_json_string "trigger" "$INPUT")
        ACTIVITY="${COMPACT_TRIGGER:-auto}"
        ;;
    SubagentStart)
        STATUS="active"
        AGENT_TYPE=$(extract_json_string "agent_type" "$INPUT")
        ACTIVITY="${AGENT_TYPE:-subagent}"
        ;;
    SubagentStop)
        STATUS="active"
        ;;
    Stop)
        STATUS="idle"
        ;;
    Notification)
        NTYPE=$(extract_json_string "notification_type" "$INPUT")
        case "$NTYPE" in
            permission_prompt|elicitation_dialog)
                STATUS="waiting"
                ;;
            idle_prompt)
                STATUS="idle"
                ;;
            *)
                STATUS="idle"
                ;;
        esac
        ;;
    ConfigChange)
        # Don't update status on config changes
        exit 0
        ;;
    *)
        STATUS="active"
        ;;
esac

# Sticky compacting: if the previous state was "compacting", keep it unless
# this is a definitive end event that means compaction is done.
if [[ "$PREV_STATE" == "compacting" && "$STATUS" == "active" ]]; then
    STATUS="compacting"
    # Preserve tool activity info so the UI can show what's happening
    ACTIVITY="${ACTIVITY:+compacting ($ACTIVITY)}"
    [[ -z "$ACTIVITY" ]] && ACTIVITY="compacting"
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Escape values that may contain special characters for JSON safety
SAFE_SESSION_ID=$(json_escape "$SESSION_ID")
SAFE_ACTIVITY=$(json_escape "$ACTIVITY")
SAFE_CWD=$(json_escape "$CWD")
SAFE_EVENT=$(json_escape "$EVENT")

# Write atomically: temp file then move (prevents partial reads)
TMP_FILE="${STATUS_FILE}.tmp.$$"
trap 'rm -f "$TMP_FILE"' EXIT

cat > "$TMP_FILE" << EOF
{"session_id":"${SAFE_SESSION_ID}","pid":${CLAUDE_PID},"ppid":${CLAUDE_PPID},"state":"${STATUS}","activity":"${SAFE_ACTIVITY}","timestamp":"${TIMESTAMP}","cwd":"${SAFE_CWD}","event":"${SAFE_EVENT}"}
EOF

mv -f "$TMP_FILE" "$STATUS_FILE"

# Notify the Claude Status app to refresh immediately (Darwin notification)
/usr/bin/notifyutil -p com.poisonpenllc.Claude-Status.session-changed 2>/dev/null || true

exit 0
