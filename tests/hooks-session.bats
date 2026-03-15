#!/usr/bin/env bats
# Tests for session/guard hooks

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

setup() {
    setup_test_env
    mkdir -p "$TEST_HOME/.claude"
    NODE_BIN_DIR="$(dirname "$(command -v node)")"
}

teardown() {
    teardown_test_env
}

setup_worktree_mock() {
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

run_worktree_guard() {
    local file_path="$1"
    run env PATH="$MOCK_BIN:$NODE_BIN_DIR:/usr/bin:/bin" HOME="$(cd "$TEST_HOME" && pwd -P)" node -e "
const h = require('$HOOKS_DIR/worktree-guard.js');
const matched = h.hooks[0].matcher('Write', {file_path: '$file_path'});
console.log(matched ? 'blocked' : 'allowed');
"
}

@test "worktree-guard: Write to worktree root path is allowed" {
    setup_worktree_mock
    run_worktree_guard "$MOCK_WT/src/main.js"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: Write to /tmp path is allowed" {
    setup_worktree_mock
    run_worktree_guard "/tmp/report.txt"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: Write to ~/.claude/ path is allowed" {
    setup_worktree_mock
    local real_home
    real_home=$(cd "$TEST_HOME" && pwd -P)
    run_worktree_guard "$real_home/.claude/specs/foo.md"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: Write to path outside worktree is blocked" {
    setup_worktree_mock
    run_worktree_guard "/Users/someone/other-repo/file.js"
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
