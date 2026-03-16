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

# ── bash-guard: module loading ──────────────────────────────────────

@test "bash-guard: loads as valid node module" {
    run node -e "const h = require('$HOOKS_DIR/bash-guard.js'); console.log(h.event + ':' + h.hooks.length)"
    [ "$status" -eq 0 ]
    [[ "$output" == "preToolUse:1" ]]
}

@test "bash-guard: non-Bash tool is ignored" {
    run_hook "$HOOKS_DIR/bash-guard.js" Read '{"command":"grep pattern file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── bash-guard: install blockers ────────────────────────────────────

@test "bash-guard: npm install is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"npm install express"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: yarn add is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"yarn add lodash"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: pnpm add is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"pnpm add express"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: pip install is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"pip install requests"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: pip3 install is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"pip3 install requests"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: go get is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"go get github.com/pkg/errors"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: cargo add is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cargo add serde"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: npm test is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"npm test"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: npm run build is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"npm run build"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: cargo build is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cargo build"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── bash-guard: legacy tool blockers ────────────────────────────────

@test "bash-guard: bare grep is blocked with /scout reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"grep pattern file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/scout"* ]]
}

@test "bash-guard: bare egrep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"egrep pattern file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: bare sed is blocked with /chisel reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"sed -i s/foo/bar/ file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/chisel"* ]]
}

@test "bash-guard: sed -i in pipeline is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"sed -i.bak s/old/new/ config.yml"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: bare find is blocked with /scout reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"find . -name *.ts"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/scout"* ]]
}

@test "bash-guard: bare awk is blocked with /chisel reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"awk -F, file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/chisel"* ]]
}

@test "bash-guard: piped grep (ls | grep) is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"ls -la | grep foo"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: git grep is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git grep pattern"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── bash-guard: file write blockers ─────────────────────────────────

@test "bash-guard: cat > file is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat > output.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"Write tool"* ]]
}

@test "bash-guard: cat >> append is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat >> logfile.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: heredoc redirect is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat <<EOF > myfile.txt\nhello\nEOF"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: redirect to /dev/null is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"some_cmd > /dev/null 2>&1"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: redirect to TMPDIR is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat > $TMPDIR/report.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: redirect to /tmp/claude is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"echo test > /tmp/claude/out.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: stderr redirect is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"some_cmd 2>/dev/stderr"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── bash-guard: inline test blockers ────────────────────────────────

@test "bash-guard: python -c with import+assert is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"python3 -c \"import json; assert True\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/test-sandbox"* ]]
}

@test "bash-guard: python -c with import+print is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"python3 -c \"import sys; print(sys.version)\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: python -c with dollar-quote is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash "{\"command\":\"python3 -c \$'import os\\nassert True'\"}"
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: simple python print is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"python3 -c \"print(42)\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: python script execution is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"python3 test_file.py"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── bash-guard: brute lookup blockers ───────────────────────────────

@test "bash-guard: grepping node_modules is blocked with /lookup reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"grep -r pattern node_modules/express"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/lookup"* ]]
}

@test "bash-guard: grepping site-packages is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat .venv/lib/python3.11/site-packages/requests/api.py"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping cargo registry is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat .cargo/registry/src/serde/lib.rs"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping go mod cache is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat /go/pkg/mod/github.com/pkg/errors/errors.go"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: cargo doc piped to grep is blocked with /fetch reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cargo doc --open | grep MyStruct"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/fetch"* || "$output" == *"/lookup"* ]]
}

@test "bash-guard: go doc piped to grep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"go doc net/http | grep Handler"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: find -exec grep is blocked with /trace reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"find . -name *.go -exec grep Handler {} +"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/trace"* || "$output" == *"/serena"* ]]
}

@test "bash-guard: find | xargs grep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"find src/ -name *.ts | xargs grep import"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping target/doc is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"grep -r MyStruct target/doc/mycrate"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: normal ls is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"ls src/"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── bash-guard: heuristic trigger blockers ──────────────────────────

@test "bash-guard: cd && git is blocked with /wt-git reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cd /some/path && git commit -m \"fix\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/wt-git"* || "$output" == *"git -C"* ]]
}

@test "bash-guard: gh pr create with cat heredoc is blocked with /gh reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr create --title \"fix\" --body \"$(cat <<EOF\nsummary\nEOF\n)\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/gh"* || "$output" == *"GitHub MCP"* ]]
}

@test "bash-guard: git -C is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git -C /some/path status"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

# ── write-guard: module loading ─────────────────────────────────────

@test "write-guard: loads as valid node module" {
    run node -e "const h = require('$HOOKS_DIR/write-guard.js'); console.log(h.event + ':' + h.hooks.length)"
    [ "$status" -eq 0 ]
    [[ "$output" == "preToolUse:1" ]]
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

@test "write-guard: lowercase todo in prose is allowed" {
    run_hook "$HOOKS_DIR/write-guard.js" Edit '{"new_string":"// need to do this next","file_path":"foo.ts"}'
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
