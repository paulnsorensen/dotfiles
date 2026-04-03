#!/usr/bin/env bats
# Tests for session/guard hooks
#
# ── Coverage manifest ───────────────────────────────────────────────
# Every hook in this file must have at least one positive and one
# negative test. When modifying hooks, update this manifest.
#
# on-session-end.sh — farewell regex in prompt field
#   "goodbye":                      → produces JSON output
#   "see you later":                → produces JSON output
#   normal text (neg):              → no output
#
# pre-compact.sh — transcript_path → .compaction-context
#   file_path extraction:           → file paths in context file
#   command extraction:             → commands in context file
#   missing transcript:             → graceful exit
#   section headers:                → ## Working directory, ## Files
#
# post-compact.sh — reads .compaction-context → JSON output
#   with context file:              → outputs content, deletes file
#   without context file:           → default COMPACTION COMPLETE
#
# post-fresh-start.sh — fresh session vs compaction resume
#   without compaction file:        → JSON suggestion output
#   with compaction file:           → silent exit
#
# commit-hesitation-guard — type: "agent" Stop hook (no command tests; agent hooks are runtime-evaluated)
# ────────────────────────────────────────────────────────────────────

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

setup() {
    setup_test_env
    mkdir -p "$TEST_HOME/.claude"
}

teardown() {
    teardown_test_env
}

# ── on-session-end ──────────────────────────────────────────────────

@test "on-session-end: farewell 'goodbye' produces JSON output" {
    run bash -c 'echo "{\"prompt\": \"goodbye\"}" | bash '"$HOOKS_DIR/on-session-end.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"'
}

@test "on-session-end: farewell 'see you' produces JSON output" {
    run bash -c 'echo "{\"prompt\": \"see you later\"}" | bash '"$HOOKS_DIR/on-session-end.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"'
}

@test "on-session-end: normal text does not match" {
    run bash -c 'echo "{\"prompt\": \"let'\''s fix this bug\"}" | bash '"$HOOKS_DIR/on-session-end.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── pre-compact / post-compact / post-fresh-start ───────────────────

@test "pre-compact: extracts file paths from transcript" {
    local transcript="$TEST_HOME/transcript.jsonl"
    echo '{"tool_input":{"file_path":"/src/main.js"}}' > "$transcript"
    echo '{"tool_input":{"file_path":"/src/util.js"}}' >> "$transcript"

    run bash -c 'echo "{\"transcript_path\": \"'"$transcript"'\"}" | bash '"$HOOKS_DIR/pre-compact.sh"
    [ "$status" -eq 0 ]
    [ -f "$TEST_HOME/.claude/.compaction-context" ]
    grep -q '/src/main.js' "$TEST_HOME/.claude/.compaction-context"
    grep -q '/src/util.js' "$TEST_HOME/.claude/.compaction-context"
}

@test "pre-compact: extracts commands from transcript" {
    local transcript="$TEST_HOME/transcript.jsonl"
    echo '{"tool_input":{"command":"npm test"}}' > "$transcript"

    run bash -c 'echo "{\"transcript_path\": \"'"$transcript"'\"}" | bash '"$HOOKS_DIR/pre-compact.sh"
    [ "$status" -eq 0 ]
    grep -q 'npm test' "$TEST_HOME/.claude/.compaction-context"
}

@test "pre-compact: missing transcript handled gracefully" {
    run bash -c 'echo "{\"transcript_path\": \"/nonexistent/file\"}" | bash '"$HOOKS_DIR/pre-compact.sh"
    [ "$status" -eq 0 ]
}

@test "pre-compact: output format includes section headers" {
    local transcript="$TEST_HOME/transcript.jsonl"
    echo '{"tool_input":{"file_path":"/src/app.js"}}' > "$transcript"

    run bash -c 'echo "{\"transcript_path\": \"'"$transcript"'\"}" | bash '"$HOOKS_DIR/pre-compact.sh"
    [ "$status" -eq 0 ]
    grep -q '## Working directory' "$TEST_HOME/.claude/.compaction-context"
    grep -q '## Files recently touched' "$TEST_HOME/.claude/.compaction-context"
}

@test "post-compact: with context file reads and outputs content" {
    echo "## Files recently touched" > "$TEST_HOME/.claude/.compaction-context"
    echo "/src/main.js" >> "$TEST_HOME/.claude/.compaction-context"

    run bash "$HOOKS_DIR/post-compact.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null
    [[ "$output" == *"/src/main.js"* ]]
}

@test "post-compact: without context file outputs default reminder" {
    rm -f "$TEST_HOME/.claude/.compaction-context"

    run bash "$HOOKS_DIR/post-compact.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null
    [[ "$output" == *"COMPACTION COMPLETE"* ]]
}

@test "post-compact: context file deleted after read" {
    echo "saved context" > "$TEST_HOME/.claude/.compaction-context"

    run bash "$HOOKS_DIR/post-compact.sh"
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_HOME/.claude/.compaction-context" ]
}

@test "post-fresh-start: without compaction file outputs JSON suggestion" {
    rm -f "$TEST_HOME/.claude/.compaction-context"

    run bash "$HOOKS_DIR/post-fresh-start.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"'
    [[ "$output" == *"Fresh session"* ]]
}

@test "post-fresh-start: with compaction file exits silently" {
    touch "$TEST_HOME/.claude/.compaction-context"

    run bash "$HOOKS_DIR/post-fresh-start.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
