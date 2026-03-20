#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for JavaScript blocking hooks (preToolUse)
#
# ── Coverage manifest ───────────────────────────────────────────────
# Every regex pattern in bash-guard.js and write-guard.js must have
# at least one positive test (fires) and one negative test (passes).
# When adding a new pattern, add its line here and write the test.
#
# bash-guard.js — INSTALL_PATTERNS (6 patterns)
#   /\bnpm\s+install\b/             → npm install, npm test (neg)
#   /\byarn\s+add\b/                → yarn add
#   /\bpnpm\s+(add|install)\b/      → pnpm add, pnpm install
#   /\bpip3?\s+install\b/           → pip install, pip3 install, pip install -r
#   /\bgo\s+get\b/                  → go get, go generate (neg), go test (neg)
#   /\bcargo\s+add\b/               → cargo add, cargo build (neg)
#
# bash-guard.js — LEGACY_TOOLS (5 patterns)
#   /^\s*(grep|egrep|fgrep)\b/      → grep, egrep, fgrep, leading whitespace, piped grep (neg), git grep (neg)
#   /^\s*sed\b/                     → bare sed (no -i)
#   /\bsed\s+-[^|]*i/              → sed -i, sed -i.bak
#   /^\s*awk\b/                     → awk, leading whitespace
#   /^\s*find\b/                    → find, leading whitespace
#
# bash-guard.js — matchFileWrite (2 block patterns, 3 allow patterns)
#   /\bcat\s*>>?\s/                 → cat >, cat >>
#   /<<[-~]?\s*['"]?\w+/ + />>?\s+/ → heredoc redirect
#   /[12]?>+\s*\/dev\/(null|stderr|stdout)/  → /dev/null (neg), /dev/stderr (neg), /dev/stdout (neg)
#   /2>&1/                          → 2>&1 (neg, stripped)
#   /\$TMPDIR|\/private\/tmp\/claude|\/tmp\/claude/ → TMPDIR (neg), /tmp/claude (neg), /private/tmp/claude (neg)
#
# bash-guard.js — matchInlineTest (4 patterns)
#   /python3?\s+-c\s+['"].*\bimport\b.*(?:\bassert\b|print\s*\()/  → import+assert, import+print
#   /python3?\s+-c\s+\$'/           → dollar-quote form
#   /python3?\s+-c\s+['"]...\bimport\b...;...(?:\bassert|print)/   → (covered by pattern 1)
#   /cat\s+<<...\bimport\b.../      → cat heredoc with import+assert
#   python (not python3):           → python -c import+assert
#   simple python print (neg):     → python3 -c print(42)
#   script execution (neg):        → python3 test_file.py
#
# bash-guard.js — DEP_CACHES (11 patterns)
#   /\.cargo\/registry/             → .cargo/registry
#   /node_modules\//                → node_modules/
#   /\.pnpm-store/                  → .pnpm-store
#   /site-packages\//               → site-packages/ (via .venv path)
#   /\.venv\/lib\//                 → (covered by site-packages test)
#   /\/go\/pkg\/mod\//              → /go/pkg/mod/
#   /GOPATH.*pkg\/mod/              → GOPATH/src/pkg/mod/
#   /\.m2\/repository\//            → .m2/repository/
#   /\.gradle\/caches\//            → .gradle/caches/
#   /\.gem\//                       → .gem/
#   /vendor\/bundle\//              → vendor/bundle/
#
# bash-guard.js — DOC_GREP (5 generators, require grep|head|tail)
#   /cargo\s+doc\b/                 → cargo doc | grep
#   /go\s+doc\b/                    → go doc | grep, go doc alone (neg)
#   /pydoc3?\b/                     → pydoc | grep, pydoc3 | head
#   /python3?\s+-c\s+.*help\s*\(/   → python help() | grep
#   /ri\s+/                         → ri | grep
#   /target\/doc\// + /grep/        → target/doc grep
#   /find\s+.*-exec\s+grep/        → find -exec grep
#   /find\s+.*\|\s*xargs\s+grep/   → find | xargs grep
#
# bash-guard.js — HEURISTIC_TRIGGERS (7 patterns)
#   /\bcd\s+\S+\s*&&\s*git\b/      → cd && git, git -C (neg)
#   /gh\s+pr\s+create\b...--body\s*"\$\(cat\b/ → gh pr create --body "$(cat
#   /\bgh\s+[^|]+\|\s*jq\b/        → gh | jq, gh --jq (neg)
#   /\bgh\s+[^|]+\|\s*(grep|head|tail|awk|sed|cut|sort|wc)\b/ → gh | grep, gh | head, gh --json (neg)
#   /\bgh\s+api\b/                 → gh api, gh pr list (neg)
#   /\bgit\s+add\b...&&\s*git\s+commit\b/ → git add && git commit, git add alone (neg)
#   /\bgit\s+commit\b.*\$\(/       → git commit with $( subst, git commit -m "msg" (neg)
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

@test "bash-guard: pnpm install is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"pnpm install"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: pip install -r is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"pip install -r requirements.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: go generate is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"go generate ./..."}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: go test is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"go test ./..."}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
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

@test "bash-guard: bare fgrep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"fgrep pattern file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grep with leading whitespace is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"  grep -r pattern src/"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: bare sed without -i is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"sed s/foo/bar/ file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/chisel"* ]]
}

@test "bash-guard: awk with leading whitespace is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"  awk -F, file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: find with leading whitespace is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"  find . -name *.js"}'
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

@test "bash-guard: redirect to /private/tmp/claude is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"echo test > /private/tmp/claude/out.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: stderr redirect is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"some_cmd 2>/dev/stderr"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: stdout redirect to /dev/stdout is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"some_cmd 1>/dev/stdout"}'
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

@test "bash-guard: python (not python3) -c with import+assert is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"python -c \"import json; assert True\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: cat heredoc with import+assert is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat <<EOF | python3\nimport os\nassert True\nEOF"}'
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

@test "bash-guard: grepping .pnpm-store is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat .pnpm-store/v3/files/pkg/index.js"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping GOPATH pkg/mod is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat GOPATH/src/pkg/mod/github.com/foo/bar.go"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping .m2/repository is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat .m2/repository/org/apache/commons/commons-lang3/3.12.0/pom.xml"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping .gradle/caches is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat .gradle/caches/modules-2/files-2.1/com.google.guava/guava/31.1-jre/source.jar"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping .gem/ is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat .gem/ruby/3.2.0/gems/rails-7.0.0/lib/rails.rb"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: grepping vendor/bundle is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"cat vendor/bundle/ruby/3.2.0/gems/rack-2.2.7/lib/rack.rb"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: pydoc piped to grep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"pydoc json | grep loads"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"pydoc"* ]]
}

@test "bash-guard: pydoc3 piped to head is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"pydoc3 requests | head -50"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: python help() piped to grep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"python3 -c \"help(json.loads)\" | grep param"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: ri piped to grep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"ri Array#map | grep return"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"ri (Ruby)"* ]]
}

@test "bash-guard: go doc without grep is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"go doc net/http"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
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
    [[ "$output" == *"/trace"* || "$output" == *"/lookup"* ]]
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

@test "bash-guard: gh pr create with cat heredoc is blocked with --body-file reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr create --title \"fix\" --body \"$(cat <<EOF\nsummary\nEOF\n)\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"--body-file"* || "$output" == *"MCP"* ]]
}

@test "bash-guard: git -C is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git -C /some/path status"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: gh pr create --body-file is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr create --title \"fix\" --body-file /tmp/pr-body.md"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: gh piped to jq is blocked with --jq reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr list --json number | jq \".[].number\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"--jq"* ]]
}

@test "bash-guard: gh piped to grep is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr list --json title | grep fix"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"--jq"* ]]
}

@test "bash-guard: gh piped to head is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh issue list | head -5"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: gh piped to sort is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr list --json number | sort -n"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: gh with --jq flag (no pipe) is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr list --json number --jq \".[].number\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: gh pr diff (no pipe) is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr diff 42"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: gh pr checks (no pipe) is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr checks 42"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: gh api is blocked with /gh reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh api repos/owner/repo/pulls/78/reviews"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/gh"* || "$output" == *"MCP"* ]]
}

@test "bash-guard: gh api with token prefix is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"GH_TOKEN=abc gh api repos/owner/repo/issues/1/comments"}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
}

@test "bash-guard: gh pr list (not gh api) is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"gh pr list --state open"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: git add && git commit is blocked with /commit reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git add file.txt && git commit -m \"fix: thing\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/commit"* ]]
}

@test "bash-guard: git commit with heredoc is blocked with /commit reference" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git commit -m \"$(cat <<'\''EOF'\''\nfix: thing\nEOF\n)\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/commit"* ]]
}

@test "bash-guard: git commit with command substitution is blocked" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git commit -m \"$(date): fix thing\""}'
    [ "$status" -eq 0 ]
    [[ "$output" == blocked:* ]]
    [[ "$output" == *"/commit"* ]]
}

@test "bash-guard: git add alone is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git add file.txt"}'
    [ "$status" -eq 0 ]
    [[ "$output" == "allowed" ]]
}

@test "bash-guard: git commit with simple message is allowed" {
    run_hook "$HOOKS_DIR/bash-guard.js" Bash '{"command":"git commit -m \"fix: simple message\""}'
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
