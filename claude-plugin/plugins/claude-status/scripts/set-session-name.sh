#!/bin/bash
# Claude Status — Set session name
#
# Updates the session's .cstatus file to include a session_name field.
# The hook script (session-status.sh) carries this name forward on
# subsequent updates by reading it from the previous .cstatus content.
#
# Usage: set-session-name.sh "<session name>"

set -eo pipefail

# shellcheck source=lib/json-utils.sh
source "${BASH_SOURCE%/*}/lib/json-utils.sh"

SESSION_NAME="$1"

if [[ -z "$SESSION_NAME" ]]; then
    echo "Usage: set-session-name.sh <session-name>" >&2
    exit 1
fi

# Find the .cstatus file by walking the ancestor PID chain.
# The script runs as: Claude -> bash -> this script, so we check
# each ancestor PID against .cstatus files to find the Claude process.
PROJECTS_DIR="${HOME}/.claude/projects"

find_cstatus_for_pid() {
    local pid="$1"
    for cstatus_file in "${PROJECTS_DIR}"/*/*.cstatus; do
        [[ -f "$cstatus_file" ]] || continue
        if grep -q "\"pid\":${pid}" "$cstatus_file" 2>/dev/null; then
            echo "$cstatus_file"
            return 0
        fi
    done
    return 1
}

CSTATUS_FILE=""
CURRENT_PID="${CLAUDE_PID:-$PPID}"
for _ in $(seq 1 8); do
    [[ "$CURRENT_PID" -gt 1 ]] || break
    CSTATUS_FILE=$(find_cstatus_for_pid "$CURRENT_PID") && break
    CURRENT_PID=$(ps -o ppid= -p "$CURRENT_PID" 2>/dev/null | tr -d ' ') || break
done

if [[ -z "$CSTATUS_FILE" ]]; then
    echo "Error: Could not find .cstatus file for any ancestor PID" >&2
    exit 1
fi

# Read the current .cstatus content and inject/replace the session_name field.
CURRENT=$(cat "$CSTATUS_FILE")
SAFE_NAME=$(json_escape "$SESSION_NAME")

# Remove existing session_name field if present, then append the new one
# before the closing brace.
UPDATED=$(echo "$CURRENT" | sed -e 's/,"session_name":"[^"]*"//' -e "s/}$/,\"session_name\":\"${SAFE_NAME}\"}/")

# Write atomically
TMP_FILE="${CSTATUS_FILE}.tmp.$$"
trap 'rm -f "$TMP_FILE"' EXIT
printf '%s\n' "$UPDATED" > "$TMP_FILE"
mv -f "$TMP_FILE" "$CSTATUS_FILE"

echo "Session name set to: ${SESSION_NAME}"

# Notify the Claude Status app to refresh
/usr/bin/notifyutil -p com.poisonpenllc.Claude-Status.session-changed 2>/dev/null || true
