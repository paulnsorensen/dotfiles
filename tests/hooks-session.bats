#!/usr/bin/env bats
# Tests for session/post-tool hooks.
#
# auto-format.js is the only registered PostToolUse hook (worktree-guard /
# write-guard were removed in PR #189).

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

setup() {
    setup_test_env
    mkdir -p "$TEST_HOME/.claude"
}

teardown() {
    teardown_test_env
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
