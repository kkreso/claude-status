#!/usr/bin/env bats
# Tests for the Claude Status session-status hook script.
#
# Run with: bats claude-plugin/tests/session-status.bats

SCRIPT="$BATS_TEST_DIRNAME/../plugins/claude-status/scripts/session-status.sh"

setup() {
    export TMPDIR="${BATS_TEST_TMPDIR}"
    PROJECT_DIR="${BATS_TEST_TMPDIR}/projects/test-project"
    mkdir -p "$PROJECT_DIR"
    SESSION_ID="test-session-abc123"
    STATUS_FILE="${PROJECT_DIR}/${SESSION_ID}.cstatus"
}

# Helper: build a minimal hook JSON payload
make_input() {
    local event="$1"
    local extra="${2:-}"
    cat <<JSON
{"hook_event_name":"${event}","session_id":"${SESSION_ID}","transcript_path":"${PROJECT_DIR}/transcript.jsonl","cwd":"/tmp/test-cwd"${extra}}
JSON
}

# Helper: run the hook script with a given event, stubbing PPID/ps/notifyutil
run_hook() {
    local event="$1"
    local extra="${2:-}"
    local input
    input=$(make_input "$event" "$extra")
    # Stub out external commands that won't work in test:
    # - PPID would be bats, not Claude
    # - ps lookup will fail or return wrong data
    # - notifyutil may not exist in CI
    # We override PPID via env and stub ps/notifyutil in PATH
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat > "${BATS_TEST_TMPDIR}/bin/ps" <<'SH'
#!/bin/bash
echo "1"
SH
    chmod +x "${BATS_TEST_TMPDIR}/bin/ps"
    cat > "${BATS_TEST_TMPDIR}/bin/notifyutil" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "${BATS_TEST_TMPDIR}/bin/notifyutil"

    PATH="${BATS_TEST_TMPDIR}/bin:$PATH" CLAUDE_PID=12345 \
        run bash "$SCRIPT" <<< "$input"
}

# Helper: extract a field from the .cstatus JSON
read_status_field() {
    local field="$1"
    sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$STATUS_FILE" | head -1
}

read_status_int() {
    local field="$1"
    sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p" "$STATUS_FILE" | head -1
}

# --- Basic event → state mapping ---

@test "SessionStart sets state to idle" {
    run_hook "SessionStart"
    [ "$status" -eq 0 ]
    [ -f "$STATUS_FILE" ]
    [ "$(read_status_field state)" = "idle" ]
}

@test "UserPromptSubmit sets state to active with thinking activity" {
    run_hook "UserPromptSubmit"
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "active" ]
    [ "$(read_status_field activity)" = "thinking" ]
}

@test "PreToolUse sets state to active with tool name" {
    run_hook "PreToolUse" ',"tool_name":"Edit"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "active" ]
    [ "$(read_status_field activity)" = "Edit" ]
}

@test "PostToolUse sets state to active" {
    run_hook "PostToolUse" ',"tool_name":"Edit"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "active" ]
}

@test "PermissionRequest sets state to waiting" {
    run_hook "PermissionRequest" ',"tool_name":"Bash"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "waiting" ]
    [ "$(read_status_field activity)" = "Bash" ]
}

@test "PreCompact sets state to compacting" {
    run_hook "PreCompact" ',"trigger":"auto"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "compacting" ]
    [ "$(read_status_field activity)" = "auto" ]
}

@test "Stop sets state to idle" {
    run_hook "Stop"
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "idle" ]
}

@test "SubagentStart sets state to active" {
    run_hook "SubagentStart" ',"agent_type":"Explore"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "active" ]
    [ "$(read_status_field activity)" = "Explore" ]
}

# --- Notification sub-types ---

@test "Notification permission_prompt sets waiting" {
    run_hook "Notification" ',"notification_type":"permission_prompt"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "waiting" ]
}

@test "Notification elicitation_dialog sets waiting" {
    run_hook "Notification" ',"notification_type":"elicitation_dialog"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "waiting" ]
}

@test "Notification idle_prompt sets idle" {
    run_hook "Notification" ',"notification_type":"idle_prompt"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "idle" ]
}

# --- SessionEnd ---

@test "SessionEnd removes the status file" {
    # Create a status file first
    run_hook "SessionStart"
    [ -f "$STATUS_FILE" ]

    run_hook "SessionEnd"
    [ "$status" -eq 0 ]
    [ ! -f "$STATUS_FILE" ]
}

# --- Sticky compacting ---

@test "compacting state persists through PreToolUse" {
    run_hook "PreCompact" ',"trigger":"auto"'
    [ "$(read_status_field state)" = "compacting" ]

    run_hook "PreToolUse" ',"tool_name":"Read"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "compacting" ]
}

@test "compacting state persists through PostToolUse" {
    run_hook "PreCompact" ',"trigger":"auto"'
    run_hook "PostToolUse" ',"tool_name":"Read"'
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "compacting" ]
}

@test "compacting state clears on UserPromptSubmit" {
    run_hook "PreCompact" ',"trigger":"auto"'
    run_hook "UserPromptSubmit"
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "active" ]
}

@test "compacting state clears on Stop" {
    run_hook "PreCompact" ',"trigger":"auto"'
    run_hook "Stop"
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "idle" ]
}

# --- ConfigChange ---

@test "ConfigChange exits without writing status" {
    run_hook "ConfigChange"
    [ "$status" -eq 0 ]
    [ ! -f "$STATUS_FILE" ]
}

# --- JSON escaping ---

@test "cwd with spaces is escaped in output" {
    local input
    input=$(cat <<JSON
{"hook_event_name":"SessionStart","session_id":"${SESSION_ID}","transcript_path":"${PROJECT_DIR}/transcript.jsonl","cwd":"/tmp/my project/src"}
JSON
    )
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat > "${BATS_TEST_TMPDIR}/bin/ps" <<'SH'
#!/bin/bash
echo "1"
SH
    chmod +x "${BATS_TEST_TMPDIR}/bin/ps"
    cat > "${BATS_TEST_TMPDIR}/bin/notifyutil" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "${BATS_TEST_TMPDIR}/bin/notifyutil"

    PATH="${BATS_TEST_TMPDIR}/bin:$PATH" CLAUDE_PID=12345 \
        run bash "$SCRIPT" <<< "$input"
    [ "$status" -eq 0 ]
    [ -f "$STATUS_FILE" ]
    [ "$(read_status_field cwd)" = "/tmp/my project/src" ]
}

# --- Missing optional fields ---

@test "handles missing tool_name gracefully" {
    run_hook "PreToolUse"
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "active" ]
}

@test "handles missing notification_type gracefully" {
    run_hook "Notification"
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "idle" ]
}

# --- PID recording ---

@test "records claude PID from PPID" {
    run_hook "SessionStart"
    [ "$status" -eq 0 ]
    [ "$(read_status_int pid)" = "12345" ]
}

# --- Unknown events ---

@test "unknown event defaults to active" {
    run_hook "SomeNewEvent"
    [ "$status" -eq 0 ]
    [ "$(read_status_field state)" = "active" ]
}
