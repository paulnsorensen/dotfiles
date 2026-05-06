#!/usr/bin/env bats
# Tests for session/guard hooks
#
# ── Coverage manifest ───────────────────────────────────────────────
# Every hook in this file must have at least one positive and one
# negative test. When modifying hooks, update this manifest.
#
# worktree-guard.js — matcher: toolName == Write/Edit + git worktree detection
#   Write inside worktree root:     → allowed
#   Write to /tmp:                  → allowed
#   Write to ~/.claude/:            → allowed
#   Write outside worktree:         → blocked
#   non-Write tool:                 → allowed (matcher returns false)
#   non-worktree context (.git):    → allowed (not a worktree)
#
# auto-format.js — PostToolUse stdin JSON
#   Write/Edit file_path:            → formatter receives edited file
#   relative file_path + cwd:        → formatter receives resolved path
#   non-PostToolUse event:           → no output / no format
# ────────────────────────────────────────────────────────────────────

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

run_worktree_guard_via_runner() {
    local file_path="$1"
    local json="{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$file_path\"}}"
    run bash -c 'printf "%s" "$1" | PATH="$2:$3:/usr/bin:/bin" HOME="$4" node "$5/hook-runner.js" worktree-guard.js' _ "$json" "$MOCK_BIN" "$NODE_BIN_DIR" "$(cd "$TEST_HOME" && pwd -P)" "$HOOKS_DIR"
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

@test "worktree-guard: hook-runner emits PreToolUse denial" {
    setup_worktree_mock
    run_worktree_guard_via_runner "/Users/someone/other-repo/file.js"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"'
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

# ── auto-format ─────────────────────────────────────────────────────

setup_fake_prettier() {
    MOCK_BIN="$TEST_HOME/mockbin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/prettier" <<'MOCKEOF'
#!/usr/bin/env bash
printf 'formatted by fake prettier\n' > "$2"
MOCKEOF
    chmod +x "$MOCK_BIN/prettier"
}

run_auto_format() {
    local json="$1"
    run bash -c 'printf "%s" "$1" | PATH="$2:$PATH" node "$3/auto-format.js"' _ "$json" "$MOCK_BIN" "$HOOKS_DIR"
}

@test "auto-format: formats PostToolUse file_path from stdin JSON" {
    setup_fake_prettier
    local target="$TEST_HOME/src/app.js"
    mkdir -p "$(dirname "$target")"
    echo 'const x=1' > "$target"

    local event
    event=$(jq -n --arg file "$target" '{hook_event_name:"PostToolUse", tool_name:"Write", tool_input:{file_path:$file}}')
    run_auto_format "$event"

    [ "$status" -eq 0 ]
    [[ "$(cat "$target")" == "formatted by fake prettier" ]]
}

@test "auto-format: resolves relative file_path against hook cwd" {
    setup_fake_prettier
    local work="$TEST_HOME/project"
    mkdir -p "$work/src"
    echo 'const x=1' > "$work/src/app.js"

    local event
    event=$(jq -n --arg cwd "$work" '{hook_event_name:"PostToolUse", cwd:$cwd, tool_name:"Edit", tool_input:{file_path:"src/app.js"}}')
    run_auto_format "$event"

    [ "$status" -eq 0 ]
    [[ "$(cat "$work/src/app.js")" == "formatted by fake prettier" ]]
}

@test "auto-format: ignores non-PostToolUse events" {
    setup_fake_prettier
    local target="$TEST_HOME/src/app.js"
    mkdir -p "$(dirname "$target")"
    echo 'const x=1' > "$target"

    local event
    event=$(jq -n --arg file "$target" '{hook_event_name:"PreToolUse", tool_name:"Write", tool_input:{file_path:$file}}')
    run_auto_format "$event"

    [ "$status" -eq 0 ]
    [[ "$(cat "$target")" == "const x=1" ]]
}

# ── settings wiring ─────────────────────────────────────────────────

@test "settings: write guard is wired for Edit and Write" {
    run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write") | .hooks[] | select(.command | contains("write-guard.js"))' "$REAL_DOTFILES_DIR/claude/settings.json"
    [ "$status" -eq 0 ]
}

@test "settings: worktree guard is wired for Edit and Write" {
    run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write") | .hooks[] | select(.command | contains("worktree-guard.js"))' "$REAL_DOTFILES_DIR/claude/settings.json"
    [ "$status" -eq 0 ]
}
