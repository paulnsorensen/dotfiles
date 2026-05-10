#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for JavaScript blocking hooks (preToolUse)
#
# ── Coverage manifest ───────────────────────────────────────────────
# Every regex pattern in write-guard.js must have at least one positive
# test (fires) and one negative test (passes). When adding a new pattern,
# add its line here and write the test.
#
# write-guard.js — RULES[0] ellipsis (4 alternations)
#   /\/\/\s*\.\.\./                 → // ...
#   /#\s*\.\.\./                    → # ...
#   /\/\*\s*\.\.\.\s*\*\//         → /* ... */
#   /\.{3}\s*(rest|remaining|similar|same)/ → ...remaining, ...similar, ...same
#   {...a, ...b} (neg):            → spread syntax allowed
#
# write-guard.js — RULES[1] placeholder (7 alternations)
#   /\bTODO\b/                      → TODO
#   /\bFIXME\b/                     → FIXME
#   /\bHACK\b/                      → HACK
#   /\bXXX\b/                       → XXX
#   /\bPLACEHOLDER\b/               → PLACEHOLDER
#   /unimplemented!\(\)/            → unimplemented!()
#   /todo!\(\)/                     → todo!()
#   lowercase "todo" (neg):         → allowed
#   TODOLIST (neg):                 → word boundary prevents match
#
# write-guard.js — RULES[2] inline test (2 patterns + skipFiles)
#   /python3?\s+-c\s+['"]...(?:import|assert|print\s*\()/  → python3 -c import, assert alone, print( alone
#   /cat\s+<</                      → cat heredoc
#   python (not python3):           → python -c import
#   skipFiles .md:                  → allowed
#   skipFiles .sh:                  → allowed
#   skipFiles .bash:                → allowed
#   skipFiles .yml:                 → allowed
#   skipFiles .yaml:                → allowed
#   skipFiles .toml:                → allowed
#   Write tool content field:       → blocked (tests content vs new_string)
# ────────────────────────────────────────────────────────────────────

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

# ── write-guard: module loading ─────────────────────────────────────

@test "write-guard: loads as valid node module" {
    run node -e "const h = require('$HOOKS_DIR/write-guard.js'); console.log(h.hooks.length)"
    [ "$status" -eq 0 ]
    [[ "$output" == "1" ]]
}

@test "write-guard: non-Edit/Write tool is ignored" {
    run_hook "$HOOKS_DIR/write-guard.js" Bash '{"new_string":"// TODO: implement"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── write-guard: ellipsis detection ─────────────────────────────────

@test "write-guard: JS comment ellipsis is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"// ... rest of implementation","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Ellipsis"* ]]
}

@test "write-guard: hash comment ellipsis is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"# ... rest of the code","file_path":"foo.py"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: block comment ellipsis is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"/* ... */","file_path":"foo.js"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: spread operator (...remaining) is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"... remaining items here","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: ... similar pattern is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"... similar to above","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: ... same pattern is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"... same as above","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: actual spread syntax is allowed" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"const merged = {...a, ...b};","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── write-guard: placeholder detection ──────────────────────────────

@test "write-guard: TODO is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"content":"function foo() { // TODO: implement }","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Placeholder"* ]]
}

@test "write-guard: FIXME is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"// FIXME: this is broken","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: HACK is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"// HACK: workaround","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: XXX is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"// XXX: needs review","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: unimplemented!() is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"fn process() { unimplemented!() }","file_path":"foo.rs"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: todo!() is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"fn process() { todo!() }","file_path":"foo.rs"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: PLACEHOLDER is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"const value = PLACEHOLDER;","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: lowercase todo in prose is allowed" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"// need to do this next","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: TODOLIST is allowed (word boundary)" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"const TODOLIST = [];","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── write-guard: inline test detection ──────────────────────────────

@test "write-guard: python -c in .ts file is blocked with /test-sandbox reference" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"import json; assert True\"","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/test-sandbox"* || "$output" == *"/wreck"* ]]
}

@test "write-guard: cat heredoc in .ts file is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"cat <<EOF > test.py","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: python -c in .md file is allowed (skipFiles)" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"import json; assert True\"","file_path":"README.md"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: python -c in .sh file is allowed (skipFiles)" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"import json; assert True\"","file_path":"setup.sh"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: python -c in .yml file is allowed (skipFiles)" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"import json; assert True\"","file_path":"ci.yml"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: python -c in .bash file is allowed (skipFiles)" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"import json; assert True\"","file_path":"setup.bash"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: python -c in .yaml file is allowed (skipFiles)" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"import json; assert True\"","file_path":"config.yaml"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: python -c in .toml file is allowed (skipFiles)" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"import json; assert True\"","file_path":"pyproject.toml"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "write-guard: python (not python3) -c is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python -c \"import os; print(os.getcwd())\"","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: python -c with assert (no import) is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"assert 1 == 1\"","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: python -c with print( (no import) is blocked" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"python3 -c \"print(42)\"","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: Write tool content field works" {
    run_hook "$HOOKS_DIR/write-guard.js" Write '{"content":"// ... rest of handlers","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "write-guard: clean code is allowed" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"const x = 42;","file_path":"foo.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
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

@test "hook-runner: blocks write-guard TODO via protocol" {
    run_via_runner write-guard.js Write '{"content":"// TODO: fix later","file_path":"test.js"}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "hook-runner: invalid JSON on stdin fails open" {
    run bash -c "echo 'not json' | node '$HOOKS_DIR/hook-runner.js' 'write-guard.js' 2>&1"
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
    run_via_runner write-guard.js Bash '{"command":"git status"}'
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "hook-runner: output is valid JSON when blocking" {
    run_via_runner write-guard.js Write '{"content":"// TODO: fix later","file_path":"test.js"}'
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
