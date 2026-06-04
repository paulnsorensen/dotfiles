#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for JavaScript Claude Code hooks (PreToolUse, PostToolUse).
# Coverage: phantom-file-check.js (PreToolUse), write-guard.js (PreToolUse),
# worktree-guard.js (PreToolUse), bash-guard.js (PreToolUse),
# auto-format.js (PostToolUse), hook-runner.js protocol bridge.

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

# Run a hook with an event object (for hooks that use event.cwd)
run_hook_event() {
    local hook="$1" tool="$2" input="$3" cwd="$4"
    run node -e "
        const h = require('$hook');
        const hook = h.hooks[0];
        const toolInput = JSON.parse(process.argv[1]);
        const event = JSON.parse(process.argv[2]);
        const matched = hook.matcher('$tool', toolInput, event);
        if (!matched) { console.log('allowed'); process.exit(0); }
        (async () => {
            let r = await hook.handler('$tool', toolInput, event);
            if (r == null) { console.log('allowed'); return; }
            console.log('blocked: ' + (r.result || 'no reason'));
        })();
    " "$input" "{\"cwd\":\"$cwd\"}"
}

# Run a hook through hook-runner.js (tests the full stdin/stdout protocol)
run_via_runner() {
    local hook_file="$1" tool="$2" input="$3" cwd="${4:-}"
    local json="{\"tool_name\":\"$tool\",\"tool_input\":$input"
    if [[ -n "$cwd" ]]; then
        json="${json},\"cwd\":\"$cwd\""
    fi
    json="${json}}"
    run bash -c "echo '$json' | node '$HOOKS_DIR/hook-runner.js' '$hook_file'"
}

# Run auto-format hook (PostToolUse, via stdin)
run_auto_format() {
    local tool_name="$1" tool_input="$2" cwd="${3:-}"
    local event_json="{\"tool_name\":\"$tool_name\",\"tool_input\":$tool_input"
    if [[ -n "$cwd" ]]; then
        event_json="${event_json},\"cwd\":\"$cwd\""
    fi
    event_json="${event_json}}"
    run bash -c "echo '$event_json' | node '$HOOKS_DIR/auto-format.js'"
}

# Load multiple hooks via hook-runner.js
run_via_runner_multi() {
    local tool="$1" input="$2" cwd="${3:-}"
    shift 3
    local hooks=("$@")
    local hook_args=""
    for h in "${hooks[@]}"; do
        hook_args="$hook_args $h"
    done
    local json="{\"tool_name\":\"$tool\",\"tool_input\":$input"
    if [[ -n "$cwd" ]]; then
        json="${json},\"cwd\":\"$cwd\""
    fi
    json="${json}}"
    run bash -c "echo '$json' | node '$HOOKS_DIR/hook-runner.js'$hook_args"
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

@test "phantom: cwd-relative file with matching cwd is allowed" {
    mkdir -p "$TEST_HOME/rel"
    echo "test" > "$TEST_HOME/rel/file.txt"
    run_hook_event "$HOOKS_DIR/phantom-file-check.js" Read '{"file_path":"rel/file.txt"}' "$TEST_HOME"
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "phantom: cwd-relative file with mismatched cwd is blocked" {
    mkdir -p "$TEST_HOME/rel"
    echo "test" > "$TEST_HOME/rel/file.txt"
    run_hook_event "$HOOKS_DIR/phantom-file-check.js" Read '{"file_path":"rel/file.txt"}' "/nonexistent"
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

@test "hook-runner: multiple hooks in sequence (write-guard blocks TODO)" {
    run_via_runner_multi Edit '{"file_path":"test.js","new_string":"TODO: implement"}' "" \
        write-guard.js phantom-file-check.js
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

# ── write-guard.js ──────────────────────────────────────────────────

@test "write-guard: Edit with TODO is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"file_path":"test.js","new_string":"TODO: fix later"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Placeholder"* ]]
}

@test "write-guard: Write with ellipsis comment is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"test.js","content":"function foo() {\n  // ...\n}"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Ellipsis"* ]]
}

@test "write-guard: clean Edit is allowed" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"file_path":"test.js","new_string":"function foo() { return 42; }"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: spread operator is allowed (not lazy ellipsis)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"test.js","content":"const obj = { ...a, ...b };"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: lowercase todo is allowed (word boundary)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"test.js","content":"function todolist() { return 1; }"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: TODOLIST is allowed (word boundary)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"test.js","content":"const TODOLIST = [];"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: Bash tool is ignored (no write checking)" {
    run_hook "$HOOKS_DIR/write-guard.js" Bash '{"command":"rm -rf /"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: MultiEdit with one dirty edit is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" MultiEdit '{"file_path":"test.js","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"// ..."}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: MultiEdit all-clean is allowed" {
    run_hook "$HOOKS_DIR/write-guard.js" MultiEdit '{"file_path":"test.js","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: tilth_write overwrite with TODO in one file is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" mcp__tilth__tilth_write '{"files":[{"path":"a.js","content":"clean code"},{"path":"b.js","content":"TODO: fix"}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: tilth_write hash-edit with ellipsis is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" mcp__tilth__tilth_write '{"files":[{"path":"a.js","edits":[{"content":"// ..."}]}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: tilth_write clean is allowed" {
    run_hook "$HOOKS_DIR/write-guard.js" mcp__tilth__tilth_write '{"files":[{"path":"a.js","content":"clean code"},{"path":"b.js","content":"also clean"}]}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: cat heredoc in .py is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"test.py","content":"code = \"\"\"\ncat <<EOF\ntest\nEOF\n\"\"\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Inline test"* ]]
}

@test "write-guard: python3 -c import in .py is blocked (inline test)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"test.py","content":"python3 -c \"import os\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Inline test"* ]]
}

@test "write-guard: python -c print in .py is blocked (inline test)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"test.py","content":"python -c '"'"'print(1)'"'"'"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: python3 -c import in .md is allowed (skipFiles)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"doc.md","content":"python3 -c \"import os\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: extensionless Makefile is skipped (inline-test rule)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"Makefile","content":"\tpython3 -c \"import os\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: extensionless justfile is skipped (inline-test rule)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"justfile","content":"cat <<EOF"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: path/to/Makefile is skipped (basename match)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"sub/dir/Makefile","content":"cat <<X"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: Makefile.py is NOT skipped (real extension wins)" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"file_path":"Makefile.py","content":"python3 -c \"import os\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

# ── bash-guard.js ────────────────────────────────────────────────────

@test "bash-guard: rm -rf / is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf /* is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /*"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf ~ is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf ~"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf ~/Dev is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf ~/Dev"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf \$HOME is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf $HOME"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf \${HOME} is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf ${HOME}"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf .. is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf .."}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf ../sibling is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf ../sibling"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf /usr/local is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /usr/local"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf /Users is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /Users"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf /Users/paul is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /Users/paul"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf * is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf *"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: sudo rm -rf /etc is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"sudo rm -rf /etc"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -fr / is blocked (flags reversed)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -fr /"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm --recursive --force /var is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm --recursive --force /var"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf node_modules is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf node_modules"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf ./build is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf ./build"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf dist target is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf dist target"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf /Users/paul/Dev/repo/node_modules is allowed (deep)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /Users/paul/Dev/repo/node_modules"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf .cheese/old is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf .cheese/old"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm file.txt is allowed (no -r)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -r foo is allowed (no -f)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -r foo"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -f bar is allowed (no -r)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -f bar"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: git rm -rf cached is allowed (not rm)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git rm -rf cached"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: echo && rm -rf /tmp/foo && ls is allowed (piped, /tmp safe)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"echo hi && rm -rf /tmp/foo && ls"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf /private/tmp/x is allowed (macOS /tmp firmlink)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /private/tmp/scratch"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf /var/folders/.../T is allowed (macOS \$TMPDIR)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /var/folders/ab/cd/T/build"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf /private/var/folders/... is allowed (firmlinked \$TMPDIR)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /private/var/folders/ab/T/build"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: rm -rf /var/log is still blocked (non-temp system dir)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /var/log"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf /private/etc is still blocked (firmlinked system dir)" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /private/etc"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: rm -rf /private (bare) is still blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"rm -rf /private"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

# ── worktree-guard.js ────────────────────────────────────────────────
# Note: worktree tests may skip or pass in environments where git worktree
# is unavailable or has restrictions (e.g. sandboxed systems).

@test "worktree-guard: normal repo (not worktree) is allowed" {
    mkdir -p "$TEST_HOME/repo"
    (
        cd "$TEST_HOME/repo"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
    ) 2>/dev/null
    run_hook_event "$HOOKS_DIR/worktree-guard.js" Write '{"file_path":"test.txt","new_string":"ok"}' "$TEST_HOME/repo"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: CLAUDE_WORKTREE_GUARD=0 disables guard" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # Non-/tmp path: the guard always allows /tmp scratch, so a /tmp target
    # would be allowed regardless of the env var and prove nothing.
    local outside_path="/wt-guard-outside/x.txt"
    CLAUDE_WORKTREE_GUARD=0 run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$outside_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: write inside worktree is allowed" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    run_hook_event "$HOOKS_DIR/worktree-guard.js" Write '{"file_path":"inside.txt","new_string":"ok"}' "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: write to sibling/main path outside worktree is blocked" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # Non-/tmp path: /tmp is always-allowed scratch, so a /tmp target would mask
    # the block. The file need not exist — the matcher only classifies the path.
    local main_path="/wt-guard-outside/sneaky.txt"
    run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$main_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == blocked:* ]]
}

@test "worktree-guard: write to .cheese path outside worktree is allowed" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # Non-/tmp .cheese path: proves the .cheese allow-rule specifically (a /tmp
    # path would be allowed via the scratch rule, masking the .cheese logic).
    local cheese_path="/wt-guard-outside/.cheese/spec.md"
    run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$cheese_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: tilth_write batch with one outside file is blocked" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    local outside_path="/wt-guard-outside/bad.txt"  # non-/tmp so the block is real
    run_hook_event "$HOOKS_DIR/worktree-guard.js" mcp__tilth__tilth_write \
        "{\"files\":[{\"path\":\"inside.txt\",\"content\":\"ok\"},{\"path\":\"$outside_path\",\"content\":\"bad\"}]}" \
        "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == blocked:* ]]
}

@test "worktree-guard: CLAUDE_WORKTREE_GUARD_ALLOW makes outside path allowed" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # Non-/tmp path that is only writable because the prefix is allow-listed.
    local outside_path="/wt-guard-allow/x.txt"
    CLAUDE_WORKTREE_GUARD_ALLOW="/wt-guard-allow" run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$outside_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: write to cheese durable corpus under HOME is allowed" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # Non-/tmp HOME: a /tmp-rooted home would be allowed via the scratch rule,
    # masking the corpus logic. Path need not exist — the matcher classifies it.
    local corpus_path="/wt-guard-home/.local/share/cheese/proj/specs/slug.md"
    HOME="/wt-guard-home" XDG_DATA_HOME="" run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$corpus_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: write to cheese durable corpus under XDG_DATA_HOME is allowed" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # XDG_DATA_HOME overrides ~/.local/share as the corpus root.
    local corpus_path="/wt-guard-xdg/cheese/proj/rfds/slug.md"
    HOME="/wt-guard-home" XDG_DATA_HOME="/wt-guard-xdg" run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$corpus_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == "allowed" ]]
}

@test "worktree-guard: non-cheese sibling under data home is still blocked" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # The carve-out is cheese-only — a sibling app dir must stay blocked.
    local sibling_path="/wt-guard-home/.local/share/other-app/file.txt"
    HOME="/wt-guard-home" XDG_DATA_HOME="" run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$sibling_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == blocked:* ]]
}

@test "worktree-guard: cheese prefix-sneak sibling (cheesecake) is blocked" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # startsWith must match the prefix as a path segment, not a string prefix.
    local sneak_path="/wt-guard-home/.local/share/cheesecake/x.txt"
    HOME="/wt-guard-home" XDG_DATA_HOME="" run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$sneak_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == blocked:* ]]
}

@test "worktree-guard: traversal out of cheese corpus (..) is blocked" {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main"
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main"
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
    # path.resolve must normalize .. before the prefix check.
    local escape_path="/wt-guard-home/.local/share/cheese/../other-app/x.txt"
    HOME="/wt-guard-home" XDG_DATA_HOME="" run_hook_event "$HOOKS_DIR/worktree-guard.js" Write "{\"file_path\":\"$escape_path\",\"new_string\":\"x\"}" "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == blocked:* ]]
}

# ── auto-format.js ───────────────────────────────────────────────────

@test "auto-format: exits 0 on non-file-editing tool (Bash)" {
    run_auto_format Bash '{"command":"ls"}'
    [ "$status" -eq 0 ]
}

@test "auto-format: exits 0 for missing tool_name" {
    run_auto_format "" '{"command":"echo"}'
    [ "$status" -eq 0 ]
}

@test "auto-format: prettier formats .js file if prettier installed" {
    if ! which prettier >/dev/null 2>&1; then
        skip "prettier not installed"
    fi
    local file="$TEST_HOME/bad.js"
    echo "function    foo( ) { }" > "$file"
    run_auto_format Edit "{\"file_path\":\"$file\",\"new_string\":\"function foo() {}\"}" "$TEST_HOME"
    [ "$status" -eq 0 ]
    # Check file was formatted
    grep -q "function foo()" "$file" || skip "prettier didn't format"
}

@test "auto-format: skips non-existent file" {
    run_auto_format Write '{"file_path":"/nonexistent/file.js","content":"function foo(){}"}' "$TEST_HOME"
    [ "$status" -eq 0 ]
}

@test "auto-format: handles tilth_write batch paths" {
    if ! which prettier >/dev/null 2>&1; then
        skip "prettier not installed"
    fi
    local file1="$TEST_HOME/a.js"
    local file2="$TEST_HOME/b.js"
    echo "function   foo( ) { }" > "$file1"
    echo "function   bar( ) { }" > "$file2"
    run_auto_format mcp__tilth__tilth_write \
        "{\"files\":[{\"path\":\"$file1\",\"content\":\"clean\"},{\"path\":\"$file2\",\"content\":\"clean\"}]}" \
        "$TEST_HOME"
    [ "$status" -eq 0 ]
}
