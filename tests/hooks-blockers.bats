#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for JavaScript blocking hooks (preToolUse)

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
            const arity = hook.handler.length;
            let r = arity >= 2 ? await hook.handler('$tool', input) : await hook.handler(input);
            if (r == null) { console.log('allowed'); return; }
            console.log('blocked: ' + (r.result || 'no reason'));
        })();
    " "$input"
}

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "block-install: npm install is blocked" {
    run_hook "$HOOKS_DIR/block-install.js" Bash '{"command":"npm install express"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-install: yarn add is blocked" {
    run_hook "$HOOKS_DIR/block-install.js" Bash '{"command":"yarn add lodash"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-install: pip install is blocked" {
    run_hook "$HOOKS_DIR/block-install.js" Bash '{"command":"pip install requests"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-install: cargo add is blocked" {
    run_hook "$HOOKS_DIR/block-install.js" Bash '{"command":"cargo add serde"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-install: npm test is allowed" {
    run_hook "$HOOKS_DIR/block-install.js" Bash '{"command":"npm test"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-install: npm run build is allowed" {
    run_hook "$HOOKS_DIR/block-install.js" Bash '{"command":"npm run build"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-file-write: cat > file is blocked" {
    run_hook "$HOOKS_DIR/block-file-write.js" Bash '{"command":"cat > output.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-file-write: heredoc redirect is blocked" {
    run_hook "$HOOKS_DIR/block-file-write.js" Bash '{"command":"cat <<EOF > myfile.txt\nhello\nEOF"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-file-write: redirect to /dev/null is allowed" {
    run_hook "$HOOKS_DIR/block-file-write.js" Bash '{"command":"some_cmd > /dev/null 2>&1"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-file-write: redirect to TMPDIR is allowed" {
    run_hook "$HOOKS_DIR/block-file-write.js" Bash '{"command":"cat > $TMPDIR/report.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-file-write: stderr redirect is allowed" {
    run_hook "$HOOKS_DIR/block-file-write.js" Bash '{"command":"some_cmd 2>/dev/stderr"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-file-write: cat >> append is also blocked" {
    run_hook "$HOOKS_DIR/block-file-write.js" Bash '{"command":"cat >> logfile.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-legacy: bare grep is blocked" {
    run_hook "$HOOKS_DIR/block-legacy-tools.js" Bash '{"command":"grep pattern file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Grep"* ]]
}

@test "block-legacy: bare sed is blocked" {
    run_hook "$HOOKS_DIR/block-legacy-tools.js" Bash '{"command":"sed -i s/foo/bar/ file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"sd"* ]]
}

@test "block-legacy: bare find is blocked" {
    run_hook "$HOOKS_DIR/block-legacy-tools.js" Bash '{"command":"find . -name *.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Glob"* ]]
}

@test "block-legacy: bare awk is blocked" {
    run_hook "$HOOKS_DIR/block-legacy-tools.js" Bash '{"command":"awk -F, file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-legacy: piped grep (ls | grep) is allowed" {
    run_hook "$HOOKS_DIR/block-legacy-tools.js" Bash '{"command":"ls -la | grep foo"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-legacy: non-Bash tool is allowed" {
    run_hook "$HOOKS_DIR/block-legacy-tools.js" Read '{"command":"grep pattern file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-brute: grepping node_modules is blocked" {
    run_hook "$HOOKS_DIR/block-brute-lookup.js" Bash '{"command":"grep -r pattern node_modules/express"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-brute: grepping site-packages is blocked" {
    run_hook "$HOOKS_DIR/block-brute-lookup.js" Bash '{"command":"cat .venv/lib/python3.11/site-packages/requests/api.py"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-brute: cargo doc piped to grep is blocked" {
    run_hook "$HOOKS_DIR/block-brute-lookup.js" Bash '{"command":"cargo doc --open | grep MyStruct"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-brute: normal directory listing is allowed" {
    run_hook "$HOOKS_DIR/block-brute-lookup.js" Bash '{"command":"ls src/"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-inline: python -c with import+assert is blocked" {
    run_hook "$HOOKS_DIR/block-inline-tests.js" Bash '{"command":"python3 -c \"import json; assert True\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-inline: python -c with import+print is blocked" {
    run_hook "$HOOKS_DIR/block-inline-tests.js" Bash '{"command":"python3 -c \"import sys; print(sys.version)\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "block-inline: simple python print is allowed" {
    run_hook "$HOOKS_DIR/block-inline-tests.js" Bash '{"command":"python3 -c \"print(42)\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "block-inline: python heredoc form is blocked" {
    run_hook "$HOOKS_DIR/block-inline-tests.js" Bash "{\"command\":\"python3 -c \$'import os\\nassert True'\"}"
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

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
