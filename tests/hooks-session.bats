#!/usr/bin/env bats
# Tests for session/guard hooks
# Covers: worktree-guard.js, on-session-end.sh, pre-compact.sh,
#         post-compact.sh, post-fresh-start.sh, de-slop-pre-commit.js,
#         tdd-assertions-pre-commit.js

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

setup() {
    export TEST_HOME="${TMPDIR:-/private/tmp/claude-501}/dotfiles-test-$$"
    export DOTFILES_STATE_DIR="$TEST_HOME/.local/state/dotfiles"
    setup_test_env
    mkdir -p "$TEST_HOME/.claude"

    # Capture node binary dir for worktree-guard tests that restrict PATH
    NODE_BIN_DIR="$(dirname "$(command -v node)")"
}

teardown() {
    teardown_test_env
}

# Helper: create mock git that simulates a worktree environment
# Sets MOCK_BIN and MOCK_WT variables for use in test
setup_worktree_mock() {
    # Use a clean path without double slashes from TMPDIR
    MOCK_WT=$(cd "$TEST_HOME" && pwd -P)/worktree
    mkdir -p "$MOCK_WT"
    MOCK_BIN="$TEST_HOME/mockbin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/git" <<MOCKEOF
#!/bin/bash
if [[ "\$1" == "rev-parse" && "\$2" == "--git-dir" ]]; then
    echo "$MOCK_WT/../main/.git/worktrees/wt1"
elif [[ "\$1" == "rev-parse" && "\$2" == "--show-toplevel" ]]; then
    echo "$MOCK_WT"
fi
MOCKEOF
    chmod +x "$MOCK_BIN/git"
}

# --- worktree-guard.js ---

@test "worktree-guard: Write to worktree root path is allowed" {
    setup_worktree_mock

    run env PATH="$MOCK_BIN:$NODE_BIN_DIR:/usr/bin:/bin" node -e "
const h = require('$HOOKS_DIR/worktree-guard.js');
const matched = h.hooks[0].matcher('Write', {file_path: '$MOCK_WT/src/main.js'});
console.log(matched ? 'blocked' : 'allowed');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: Write to /tmp path is allowed" {
    setup_worktree_mock

    run env PATH="$MOCK_BIN:$NODE_BIN_DIR:/usr/bin:/bin" node -e "
const h = require('$HOOKS_DIR/worktree-guard.js');
const matched = h.hooks[0].matcher('Write', {file_path: '/tmp/report.txt'});
console.log(matched ? 'blocked' : 'allowed');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: Write to ~/.claude/ path is allowed" {
    setup_worktree_mock
    local real_home
    real_home=$(cd "$TEST_HOME" && pwd -P)

    run env PATH="$MOCK_BIN:$NODE_BIN_DIR:/usr/bin:/bin" HOME="$real_home" node -e "
const h = require('$HOOKS_DIR/worktree-guard.js');
const matched = h.hooks[0].matcher('Write', {file_path: '$real_home/.claude/specs/foo.md'});
console.log(matched ? 'blocked' : 'allowed');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: Write to path outside worktree is blocked" {
    setup_worktree_mock
    local real_home
    real_home=$(cd "$TEST_HOME" && pwd -P)

    run env PATH="$MOCK_BIN:$NODE_BIN_DIR:/usr/bin:/bin" HOME="$real_home" node -e "
const h = require('$HOOKS_DIR/worktree-guard.js');
const matched = h.hooks[0].matcher('Write', {file_path: '/Users/someone/other-repo/file.js'});
console.log(matched ? 'blocked' : 'allowed');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "blocked" ]]
}

@test "worktree-guard: non-Write tool passes through" {
    run node -e "
const h = require('$HOOKS_DIR/worktree-guard.js');
const matched = h.hooks[0].matcher('Read', {file_path: '/some/random/path'});
console.log(matched ? 'blocked' : 'allowed');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: non-worktree context passes through" {
    # Mock git to return a normal .git dir (not under worktrees/)
    MOCK_BIN="$TEST_HOME/mockbin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/git" <<'MOCKEOF'
#!/bin/bash
if [[ "$1" == "rev-parse" && "$2" == "--git-dir" ]]; then
    echo ".git"
fi
MOCKEOF
    chmod +x "$MOCK_BIN/git"

    run env PATH="$MOCK_BIN:$NODE_BIN_DIR:/usr/bin:/bin" node -e "
const h = require('$HOOKS_DIR/worktree-guard.js');
const matched = h.hooks[0].matcher('Write', {file_path: '/some/outside/path'});
console.log(matched ? 'blocked' : 'allowed');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# --- on-session-end.sh ---

@test "on-session-end: farewell 'goodbye' produces JSON output" {
    run bash -c 'echo "{\"prompt\": \"goodbye\"}" | bash '"$HOOKS_DIR/on-session-end.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"'
}

@test "on-session-end: farewell 'see you' produces JSON output" {
    run bash -c 'echo "{\"prompt\": \"see you later\"}" | bash '"$HOOKS_DIR/on-session-end.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput' > /dev/null
}

@test "on-session-end: normal text does not match" {
    run bash -c 'echo "{\"prompt\": \"let'\''s fix this bug\"}" | bash '"$HOOKS_DIR/on-session-end.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "on-session-end: output is valid JSON" {
    run bash -c 'echo "{\"prompt\": \"good night\"}" | bash '"$HOOKS_DIR/on-session-end.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
}

# --- pre-compact.sh ---

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

# --- post-compact.sh ---

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

@test "post-compact: output is valid JSON" {
    run bash "$HOOKS_DIR/post-compact.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
}

# --- post-fresh-start.sh ---

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

@test "post-fresh-start: output is valid JSON when produced" {
    rm -f "$TEST_HOME/.claude/.compaction-context"

    run bash "$HOOKS_DIR/post-fresh-start.sh"
    [ "$status" -eq 0 ]
    echo "$output" | jq empty
}

# --- de-slop-pre-commit.js ---

@test "de-slop: git commit command matched" {
    run node -e "
const h = require('$HOOKS_DIR/de-slop-pre-commit.js');
const m = h.hooks[0].matcher('Bash', {command: 'git commit -m \"feat: add\"'});
console.log(m ? 'matched' : 'skipped');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "matched" ]]
}

@test "de-slop: git status command not matched" {
    run node -e "
const h = require('$HOOKS_DIR/de-slop-pre-commit.js');
const m = h.hooks[0].matcher('Bash', {command: 'git status'});
console.log(m ? 'matched' : 'skipped');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "skipped" ]]
}

# --- tdd-assertions-pre-commit.js ---

@test "tdd-assertions: git commit command matched" {
    run node -e "
const h = require('$HOOKS_DIR/tdd-assertions-pre-commit.js');
const m = h.hooks[0].matcher('Bash', {command: 'git commit -m \"test: add checks\"'});
console.log(m ? 'matched' : 'skipped');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "matched" ]]
}

@test "tdd-assertions: git diff command not matched" {
    run node -e "
const h = require('$HOOKS_DIR/tdd-assertions-pre-commit.js');
const m = h.hooks[0].matcher('Bash', {command: 'git diff HEAD'});
console.log(m ? 'matched' : 'skipped');
"
    [ "$status" -eq 0 ]
    [[ "$output" == "skipped" ]]
}
