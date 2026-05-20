#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for JavaScript blocking hooks (preToolUse) — currently only
# phantom-file-check.js plus the hook-runner.js protocol bridge. The
# write-guard / worktree-guard hooks were removed in PR #189; their
# tests went with them.

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

run_hook() {
    local hook="$1" tool="$2" input="$3"
    run node -e "
        const h = require('$hook');
        const hook = h.hooks[0];
        const input = JSON.parse(process.argv[1]);
        const matched = hook.matcher('$tool', input);
        if (!matched) { console.log('allowed'); process.exit(0); }
        (async () => {
            let r = await hook.handler('$tool', input);
            if (r == null) { console.log('allowed'); return; }
            console.log('blocked: ' + (r.result || 'no reason'));
        })();
    " "$input"
}

# Run a hook through hook-runner.js (tests the full stdin/stdout protocol)
run_via_runner() {
    local hook_file="$1" tool="$2" input="$3"
    local json="{\"tool_name\":\"$tool\",\"tool_input\":$input}"
    run bash -c "echo '$json' | node '$HOOKS_DIR/hook-runner.js' '$hook_file'"
}

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# ── phantom-file-check ──────────────────────────────────────────────

@test "phantom: non-existent file is blocked" {
    run_hook "$HOOKS_DIR/phantom-file-check.js" Read '{"file_path":"/nonexistent/path/foo.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "phantom: existing file is allowed" {
    local real_file="$TEST_HOME/real-file.txt"
    echo "content" > "$real_file"
    run_hook "$HOOKS_DIR/phantom-file-check.js" Read "{\"file_path\":\"$real_file\"}"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "phantom: missing file_path returns allowed (null guard)" {
    run_hook "$HOOKS_DIR/phantom-file-check.js" Read '{}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "phantom: non-Read tool is ignored (matcher returns false)" {
    run_hook "$HOOKS_DIR/phantom-file-check.js" Bash '{"file_path":"/nonexistent/foo.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "phantom: directory path that exists is allowed" {
    run_hook "$HOOKS_DIR/phantom-file-check.js" Read "{\"file_path\":\"$TEST_HOME\"}"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "phantom: path field also works (alternate key)" {
    run_hook "$HOOKS_DIR/phantom-file-check.js" Read '{"path":"/nonexistent/alternate.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

# ── hook-runner.js protocol bridge ─────────────────────────────────

@test "hook-runner: blocks phantom file via protocol" {
    run_via_runner phantom-file-check.js Read '{"file_path":"/nonexistent/file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook-runner: allows existing file via protocol" {
    local real_file="$TEST_HOME/runner-test.txt"
    echo "content" > "$real_file"
    local json="{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$real_file\"}}"
    run bash -c "echo '$json' | node '$HOOKS_DIR/hook-runner.js' 'phantom-file-check.js'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "hook-runner: invalid JSON on stdin fails open" {
    run bash -c "echo 'not json' | node '$HOOKS_DIR/hook-runner.js' 'phantom-file-check.js' 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"invalid JSON"* ]]
}

@test "hook-runner: missing hook file fails open with error" {
    run bash -c "echo '{}' | node '$HOOKS_DIR/hook-runner.js' 'nonexistent.js' 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed to load"* ]]
}

@test "hook-runner: missing argument exits with error" {
    run bash -c "echo '{}' | node '$HOOKS_DIR/hook-runner.js' 2>&1"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing hook file"* ]]
}

@test "hook-runner: non-matching tool passes through" {
    # phantom-file-check matches Read; Bash is a no-op.
    run_via_runner phantom-file-check.js Bash '{"command":"git status"}'
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "hook-runner: output is valid JSON when blocking" {
    # Trigger phantom-file-check on a nonexistent path so the runner has
    # to serialize a deny decision.
    run_via_runner phantom-file-check.js Read '{"file_path":"/nonexistent/output-shape-check.txt"}'
    [ "$status" -eq 0 ]
    # Verify it parses as JSON with hookSpecificOutput structure
    echo "$output" | node -e "
        let d = '';
        process.stdin.on('data', c => d += c);
        process.stdin.on('end', () => {
            const o = JSON.parse(d);
            if (!o.hookSpecificOutput) process.exit(1);
            if (o.hookSpecificOutput.hookEventName !== 'PreToolUse') process.exit(1);
            if (!['deny','allow','ask','defer'].includes(o.hookSpecificOutput.permissionDecision)) process.exit(1);
        });
    "
}
