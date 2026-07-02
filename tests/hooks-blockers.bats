#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for JavaScript Claude Code hooks (PreToolUse, PostToolUse).
# Coverage: worktree-guard.js (PreToolUse), auto-format.js (PostToolUse),
# hook-runner.js protocol bridge.

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

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

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

# ── hook-runner.js protocol bridge ─────────────────────────────────
# Exercised through worktree-guard.js — the guard hook-runner wraps in
# production (settings.json PreToolUse Edit|Write|MultiEdit|tilth_write).

setup_worktree() {
    mkdir -p "$TEST_HOME/main"
    (
        cd "$TEST_HOME/main" || return 1
        GIT_TEMPLATE_DIR="" git init -q 2>/dev/null
        git config user.email "t@e"
        git config user.name "t"
        echo "x" > f.txt && git add f.txt && git commit -qm "x" 2>/dev/null
    ) 2>/dev/null
    cd "$TEST_HOME/main" || return 1
    git worktree add ../wt -b wtbranch 2>/dev/null || skip "git worktree unavailable"
}

@test "hook-runner: blocks out-of-worktree write via protocol" {
    setup_worktree
    run_via_runner worktree-guard.js Write '{"file_path":"/wt-guard-outside/x.txt","new_string":"x"}' "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook-runner: allows in-worktree write via protocol" {
    setup_worktree
    run_via_runner worktree-guard.js Write '{"file_path":"inside.txt","new_string":"ok"}' "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
    [[ -z "$output" ]]
}

@test "hook-runner: invalid JSON on stdin fails open" {
    run bash -c "echo 'not json' | node '$HOOKS_DIR/hook-runner.js' 'worktree-guard.js' 2>&1"
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
    # worktree-guard matches Edit|Write|MultiEdit|tilth_write; Bash is a no-op.
    run_via_runner worktree-guard.js Bash '{"command":"git status"}'
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "hook-runner: output is valid JSON when blocking" {
    setup_worktree
    run_via_runner worktree-guard.js Write '{"file_path":"/wt-guard-outside/shape.txt","new_string":"x"}' "$TEST_HOME/wt"
    [ "$status" -eq 0 ]
    if [[ "$output" == *"couldn't create cache file"* ]]; then
        skip "git xcrun permissions (sandbox issue)"
    fi
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
