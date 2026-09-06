#!/usr/bin/env bats
# Tests for the tool-reroute PreToolUse hook (harness-agnostic).
#   agents/hooks/tool-reroute.sh  — bash bridge (self-locating, overrideable harness)
#   agents/lib/tool-reroute.js    — dispatcher (search → cd-git → io → delegate)
#   agents/lib/tool-reroute/{shell,search,cd-git,io}.js — lexer + modules
#
# WHY: hard-denying grep/cat/find does not stop the model RETRYING — the static
# permissions_deny even overrides a hook deny, so the redirect never lands. This
# hook instead REWRITES the wrong-tool call to its tilth/wt-git shell equivalent
# via updatedInput (transparent, one step), DENIES only the two cross-tool cases
# with no shell target (the Grep/Glob tools, write-redirects), and DELEGATES
# everything else to rtk so non-reroute commands keep their compaction. The
# rewrite tests assert the exact updatedInput.command; the delegate/fail-open
# tests encode that a non-reroute or broken hook never blocks a call.

load test_helper

HOOK_SH="$REAL_DOTFILES_DIR/agents/hooks/tool-reroute.sh"
HOOK_JS="$REAL_DOTFILES_DIR/agents/lib/tool-reroute.js"
MOD_DIR="$REAL_DOTFILES_DIR/agents/lib/tool-reroute"

setup_file() {
    export GUARD_MASTER="$BATS_FILE_TMPDIR/guard-mocks"
    mkdir -p "$GUARD_MASTER/hooks" "$GUARD_MASTER/lib/tool-reroute"
    cp "$HOOK_SH" "$GUARD_MASTER/hooks/tool-reroute.sh"
    cp "$HOOK_JS" "$GUARD_MASTER/lib/tool-reroute.js"
    cp "$MOD_DIR"/*.js "$GUARD_MASTER/lib/tool-reroute/"
    cp "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$GUARD_MASTER/lib/jsonl-log.js"
    chmod +x "$GUARD_MASTER/hooks/tool-reroute.sh"
}

# Symlink the setup_file-built master into a deploy root. Measurements showed
# a first-exec delay for fresh script inodes. Symlinking reuses the target inode
# and improved timings; the mechanism is unspecified.
deploy_reroute() {
    local root="$1"
    mkdir -p "$root/hooks" "$root/lib/tool-reroute"
    ln -s "$GUARD_MASTER/hooks/tool-reroute.sh" "$root/hooks/tool-reroute.sh"
    ln -s "$GUARD_MASTER/lib/tool-reroute.js" "$root/lib/tool-reroute.js"
    ln -s "$GUARD_MASTER/lib/jsonl-log.js" "$root/lib/jsonl-log.js"
    local f
    for f in "$GUARD_MASTER/lib/tool-reroute/"*; do
        ln -s "$f" "$root/lib/tool-reroute/$(basename "$f")"
    done
}

setup() {
    setup_test_env
    # Mirror the deployed layout: <root>/hooks/<bridge> + <root>/lib/<logic>
    # + <root>/lib/tool-reroute/<modules>. The bridge defaults to Claude.
    DEPLOY="$TEST_HOME/.claude"
    deploy_reroute "$DEPLOY"
    W="$REAL_DOTFILES_DIR"   # a real dir to stand in as the event cwd
    export CLAUDE_TOOL_REROUTE_LOG_DIR="$BATS_TEST_TMPDIR/reroute-log"
}

teardown() { teardown_test_env; }

# Raw hook stdout for a Bash command event (empty when allowed with no rewrite).
out_for() {
    local cmd="$1" json
    json=$(jq -nc --arg c "$cmd" --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    printf '%s' "$output"
}

# Raw hook stdout for an arbitrary tool + tool_input (Grep/Glob carry a pattern).
out_for_input() {
    local tool="$1" input_json="$2" json
    json=$(jq -nc --arg t "$tool" --argjson i "$input_json" --arg w "$W" \
        '{tool_name:$t, tool_input:$i, cwd:$w}')
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    printf '%s' "$output"
}

decision() { jq -r '.hookSpecificOutput.permissionDecision' <<<"$1"; }
newcmd()   { jq -r '.hookSpecificOutput.updatedInput.command' <<<"$1"; }
reason()   { jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$1"; }
no_permission_decision() { jq -e '.hookSpecificOutput | has("permissionDecision") | not' <<<"$1" >/dev/null; }

# A stub rtk that consumes the piped event and prints nothing — the silent
# case a cd-strip hit's rtk delegate call falls back from.
SILENT_STUB='cat >/dev/null'

# A stub script body that records rtk's stdin verbatim to <dir>/rtk-stdin.json
# and prints nothing, so a negative cd-strip case can assert rtk actually ran
# and received the untouched original command.
record_stub() {
    printf 'cat >"%s/rtk-stdin.json"\n' "$1"
}

# Run out_for with a stub rtk placed first on PATH, so a strip hit's rtk
# delegate call is deterministic and never depends on a real rtk install.
out_for_rtk() {
    local cmd="$1" script="$2" json
    local stub="$BATS_TEST_TMPDIR/rtk-stub-bin"
    mkdir -p "$stub"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$script"; } >"$stub/rtk"
    chmod +x "$stub/rtk"
    local nodedir; nodedir="$(dirname "$(command -v node)")"
    json=$(jq -nc --arg c "$cmd" --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')
    run env PATH="$stub:$nodedir:/usr/bin:/bin" bash -c "printf '%s' '$json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    printf '%s' "$output"
}

# Variant that passes JSON as a shell argument, preserving literal apostrophes.
out_for_rtk_safe() {
    local cmd="$1" script="$2" json
    local stub="$BATS_TEST_TMPDIR/rtk-stub-bin"
    mkdir -p "$stub"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$script"; } >"$stub/rtk"
    chmod +x "$stub/rtk"
    local nodedir; nodedir="$(dirname "$(command -v node)")"
    json=$(jq -nc --arg c "$cmd" --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')
    # shellcheck disable=SC2016
    # Intentional: preserve positional parameters for the inner shell.
    run env PATH="$stub:$nodedir:/usr/bin:/bin" bash -c 'printf "%s" "$1" | "$2"' bash "$json" "$DEPLOY/hooks/tool-reroute.sh"
    [ "$status" -eq 0 ]
    printf '%s' "$output"
}

# ── tool-reroute/search: grep/rg/ag/ack/find → tilth (rewrite) ───────────

@test "tool-reroute/search: bash grep rewrites to tilth with --scope" {
    local out; out=$(out_for 'grep foo .')
    [[ "$(decision "$out")" == "allow" ]]
    [[ "$(newcmd "$out")" == "tilth foo --scope ." ]]
}

@test "tool-reroute/search: bash grep with no path rewrites to bare tilth" {
    local out; out=$(out_for 'grep -rn foo')
    [[ "$(newcmd "$out")" == "tilth foo" ]]
}

@test "tool-reroute/search: rg/ag/ack all rewrite to tilth" {
    [[ "$(newcmd "$(out_for 'rg bar src/')")" == "tilth bar --scope src/" ]]
    [[ "$(newcmd "$(out_for 'ag baz')")" == "tilth baz" ]]
    [[ "$(newcmd "$(out_for 'ack qux')")" == "tilth qux" ]]
}

@test "tool-reroute/search: find -name rewrites to positional tilth glob" {
    # tilth has no --glob flag; QUERY is positional and accepts a glob pattern.
    local out; out=$(out_for 'find . -name foo.js')
    [[ "$(newcmd "$out")" == "tilth foo.js --scope ." ]]
}

@test "tool-reroute/search: a glob pattern is shell-quoted in the rewrite" {
    # *.js must survive as a runnable single-quoted arg, not be left bare.
    local out; out=$(out_for "find . -name '*.js'")
    [[ "$(newcmd "$out")" == "tilth '*.js' --scope ." ]]
}

@test "tool-reroute/search: the rewrite reason records orig → new" {
    local out; out=$(out_for 'grep foo .')
    [[ "$(reason "$out")" == "tool-reroute: grep foo . → tilth foo --scope ." ]]
}

@test "tool-reroute/search: exotic grep (-l) is NOT rewritten to tilth (delegated)" {
    # -l changes semantics (file list, not matches); tilth can't express it, so
    # it must fall through to rtk, never a tilth rewrite or a hard block.
    local out; out=$(out_for 'grep -l foo .')
    [[ "$out" != *"tilth foo"* ]]
}

@test "tool-reroute/search: find -iname (case-insensitive) is NOT rewritten (tilth glob is case-sensitive)" {
    # tilth's positional glob is case-sensitive, so -iname '*.JS' would silently
    # narrow the match set (matches UPPER.JS but not lower.js); the call must
    # delegate, never become a literal tilth glob rewrite.
    local out; out=$(out_for 'find . -iname "*.JS"')
    [[ "$out" != *'"command":"tilth'* ]]
    ! denied "$out"
}

@test "tool-reroute/search: non-name find is NOT rewritten (delegated)" {
    # A -size predicate is a real filesystem op tilth can't express, so it must
    # never become a tilth rewrite — it falls through to rtk delegation.
    local out; out=$(out_for 'find . -size +100M')
    [[ "$(newcmd "$out")" != tilth* ]]
}

@test "tool-reroute/search: a piped grep is NOT rewritten (delegated, not unfaithful)" {
    # `cat f | grep foo` means search-in-f; rewriting to `tilth foo` would drop
    # the file scope, so the multi-segment shape delegates instead.
    local out; out=$(out_for 'cat f.txt | grep foo')
    [[ "$out" != *"tilth foo"* ]]
}

@test "tool-reroute/search: the Grep tool denies and names tilth_search" {
    local out; out=$(out_for_input Grep '{"pattern":"foo"}')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$out" == *tilth_search* ]]
}

@test "tool-reroute/search: the Glob tool denies" {
    local out; out=$(out_for_input Glob '{"pattern":"**/*.js"}')
    [[ "$(decision "$out")" == "deny" ]]
}

@test "tool-reroute/search: a binary name inside a quoted echo arg does not trip" {
    # 'grep' lives inside a string literal, not the command word — no rewrite.
    local out; out=$(out_for 'echo "run grep later"')
    [[ "$out" != *"tilth"* ]]
}

# ── tool-reroute/cd-git: cd <path> && git … → wt-git <path> <args> ────────

@test "tool-reroute/cd-git: cd && git rewrites to wt-git" {
    local out; out=$(out_for 'cd /repo && git status')
    [[ "$(decision "$out")" == "allow" ]]
    [[ "$(newcmd "$out")" == "wt-git /repo status" ]]
}

@test "tool-reroute/cd-git: the rewrite carries the cd path and all git args" {
    local out; out=$(out_for 'cd /r && git log --oneline')
    [[ "$(newcmd "$out")" == "wt-git /r log --oneline" ]]
}

@test "tool-reroute/cd-git: cd && gh is NOT rewritten (wt-git is git-only)" {
    local out; out=$(out_for 'cd /repo && gh pr list')
    [[ "$out" != *"wt-git"* ]]
}

@test "tool-reroute/cd-git: a trailing segment after git is NOT rewritten" {
    # `cd /r && git status && echo done` is not the clean two-segment shape.
    local out; out=$(out_for 'cd /r && git status && echo done')
    [[ "$out" != *"wt-git"* ]]
}

# ── tool-reroute/io: bare cat → tilth (rewrite); write-redirect → deny ────

@test "tool-reroute/io: bare cat rewrites to tilth" {
    local out; out=$(out_for 'cat README.md')
    [[ "$(decision "$out")" == "allow" ]]
    [[ "$(newcmd "$out")" == "tilth README.md" ]]
}

@test "tool-reroute/io: cat with a flag is NOT rewritten to tilth (delegated)" {
    local out; out=$(out_for 'cat -n file.txt')
    [[ "$out" != *'"command":"tilth'* ]]
}

@test "tool-reroute/io: echo write-redirect denies and names tilth_write" {
    local out; out=$(out_for 'echo hello > out.txt')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$out" == *tilth_write* ]]
}

@test "tool-reroute/io: append redirect denies" {
    [[ "$(decision "$(out_for 'printf x >> notes.md')")" == "deny" ]]
}

@test "tool-reroute/io: a redirect operator inside a quoted string does not trip" {
    local out; out=$(out_for 'echo "a > b"')
    [[ "$out" != *'"permissionDecision":"deny"'* ]]
}

# ── tool-reroute/delegate: non-reroute Bash → rtk hook ───────────────────

@test "tool-reroute/delegate: plain git is handed to rtk (rtk git …)" {
    # No module owns `git status`; the dispatcher delegates to `rtk hook claude`
    # and echoes rtk's stdout verbatim. Stub rtk on PATH (mock externals — the
    # repo never assumes a real rtk install) so the delegation wiring is tested
    # deterministically; the rtk-absent fail-open path is covered separately.
    local stub="$TEST_HOME/rtk-stub-bin"
    mkdir -p "$stub"
    cat >"$stub/rtk" <<'RTK'
#!/usr/bin/env bash
cat >/dev/null   # consume the piped PreToolUse event
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"rtk git status"}}}'
RTK
    chmod +x "$stub/rtk"
    local nodedir; nodedir="$(dirname "$(command -v node)")"
    local json; json=$(jq -nc --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:"git status"}, cwd:$w}')
    run env PATH="$stub:$nodedir:/usr/bin:/bin" bash -c "printf '%s' '$json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    # the stable signal that delegation happened is rtk's rewritten command.
    [[ "$(newcmd "$output")" == "rtk git status" ]]
}

@test "tool-reroute/delegate: rtk absent fails open (allow, empty)" {
    # node present but rtk off PATH → spawn ENOENT → fail open, command unchanged.
    local nodedir; nodedir="$(dirname "$(command -v node)")"
    local json; json=$(jq -nc --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:"git status"}, cwd:$w}')
    run env PATH="$nodedir:/usr/bin:/bin" bash -c "printf '%s' '$json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

# ── tool-reroute: rtk-prefix stripping ───────────────────────────────────

@test "tool-reroute/search: a leading rtk wrapper is stripped before detection" {
    [[ "$(newcmd "$(out_for 'rtk grep foo src')")" == "tilth foo --scope src" ]]
}

@test "tool-reroute/search: a leading rtk proxy wrapper is stripped too" {
    [[ "$(newcmd "$(out_for 'rtk proxy grep bar')")" == "tilth bar" ]]
}

# ── tool-reroute: protocol / fail-open ───────────────────────────────────

@test "tool-reroute: rewrite payload is a valid PreToolUse allow + updatedInput" {
    local out; out=$(out_for 'grep foo .')
    [[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" == "PreToolUse" ]]
    [[ "$(decision "$out")" == "allow" ]]
    [[ -n "$(newcmd "$out")" ]]
}

@test "tool-reroute: deny payload is a valid PreToolUse decision" {
    local out; out=$(out_for_input Grep '{"pattern":"foo"}')
    [[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" == "PreToolUse" ]]
    [[ "$(decision "$out")" == "deny" ]]
    [[ -n "$(reason "$out")" ]]
}

@test "tool-reroute: malformed stdin fails open (allow, exit 0)" {
    run bash -c "printf 'not json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "tool-reroute: missing logic file fails open (allow, exit 0)" {
    rm "$DEPLOY/lib/tool-reroute.js"
    run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"grep x .\"}}' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "tool-reroute: a non-matching tool is allowed (no output)" {
    local out; out=$(out_for_input Read '{"file_path":"/x"}')
    [[ -z "$out" ]]
}

# ── deploy wiring ────────────────────────────────────────────────────────

@test "tool-reroute: registry registers tool-reroute for claude matching Bash|Grep|Glob" {
    local reg="$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"
    [[ "$(yq -r '.hooks.tool-reroute.event' "$reg")" == "PreToolUse" ]]
    [[ "$(yq -r '.hooks.tool-reroute.script' "$reg")" == "agents/hooks/tool-reroute.sh" ]]
    [[ "$(yq -r '.hooks.tool-reroute.matcher' "$reg")" == "Bash|Grep|Glob" ]]
    [[ "$(yq -r '.hooks.tool-reroute.harnesses | join(",")' "$reg")" == "claude" ]]
    [[ "$(yq -r '.hooks.tool-reroute.shared_assets[0]' "$reg")" == "agents/lib/tool-reroute.js" ]]
    [[ "$(yq -r '.hooks.tool-reroute.shared_assets | length' "$reg")" -ge 5 ]]
}

@test "tool-reroute: the standalone rtk hook claude registration is removed from claude settings" {
    local settings="$REAL_DOTFILES_DIR/chezmoi/dot_claude/create_settings.json"
    run jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command=="rtk hook claude")' "$settings"
    [ "$status" -ne 0 ]   # must NOT be present
}

@test "tool-reroute: permissions profile allows tilth and un-denies the search tools" {
    local prof="$REAL_DOTFILES_DIR/profiles/_permissions/profile.yaml"
    # rewritten tilth commands run without a prompt
    run yq -e '.settings.permissions_allow[] | select(. == "Bash(tilth:*)")' "$prof"
    [ "$status" -eq 0 ]
    # the hook owns search routing now, so the static denies are gone
    run yq -e '.settings.permissions_deny[] | select(. == "Grep" or . == "Glob" or . == "Bash(grep:*)")' "$prof"
    [ "$status" -ne 0 ]
    # the rg allow stays removed; the rtk-proxy git-grep tunnel stays denied
    run yq -e '.settings.permissions_allow[] | select(. == "Bash(rg:*)")' "$prof"
    [ "$status" -ne 0 ]
    run yq -e '.settings.permissions_deny[] | select(. == "Bash(rtk proxy git grep:*)")' "$prof"
    [ "$status" -eq 0 ]
}

# ── press hardening: the never-hard-block contract ───────────────────────
# The rewrite-not-deny design hinges on this: any wrong-tool call tilth cannot
# faithfully express must degrade to rtk delegation (a prompt at worst), never
# a hook DENY. A regression that turned any fall-through into a deny would
# reinstate the exact retry-loop trap the hook was built to remove. The
# original suite asserts these shapes are not *rewritten*; here we lock the
# stronger, essential half — they are never *blocked*.

denied() { [[ "$1" == *'"permissionDecision":"deny"'* ]]; }

@test "tool-reroute: exotic/fall-through shapes delegate, never hard-block" {
    local cmd out
    for cmd in \
        'grep -l foo .' \
        'grep -rl foo' \
        'grep --include=*.js foo .' \
        'grep foo dir1 dir2' \
        'find . -size +100M' \
        'cat f.txt | grep foo' \
        'cat -n file.txt' \
        'cd /r && gh pr list'; do
        out=$(out_for "$cmd")
        if denied "$out"; then
            echo "must delegate, not DENY: $cmd -> $out" >&2
            return 1
        fi
    done
}

@test "tool-reroute/search: a fused exotic short flag (-rl) is NOT rewritten" {
    # The `l` fused into `-rl` is semantic (file list), so tilth can't express
    # it — the whole call must fall through, not rewrite on the clean `-r`.
    local out; out=$(out_for 'grep -rl foo')
    [[ "$out" != *"tilth foo"* ]]
}

@test "tool-reroute/search: a long flag forces delegation (no tilth rewrite)" {
    local out; out=$(out_for 'grep --include=*.js foo .')
    [[ "$out" != *'"command":"tilth'* ]]
}

@test "tool-reroute/search: two path operands fall through (tilth takes one scope)" {
    # pattern + two paths = 3 operands > the 2 tilth can carry, so delegate.
    local out; out=$(out_for 'grep foo dir1 dir2')
    [[ "$out" != *'"command":"tilth'* ]]
}

@test "tool-reroute/search: grep -i (case-insensitive) is NOT rewritten (tilth is case-sensitive)" {
    # tilth's positional query is case-sensitive, so -i Foo would silently match
    # a narrower set; the call must delegate, never become a literal tilth rewrite.
    local out; out=$(out_for 'grep -i Foo .')
    [[ "$out" != *'"command":"tilth'* ]]
    ! denied "$out"
}

@test "tool-reroute/search: a regex-metachar pattern is NOT rewritten (tilth matches literally)" {
    # `a.*b` is a regex in grep but a literal substring in tilth; rewriting it
    # would silently change the match set, so a metachar pattern delegates.
    local out; out=$(out_for 'grep "a.*b" src/')
    [[ "$out" != *'"command":"tilth'* ]]
    ! denied "$out"
}

# ── press hardening: cd-git chain separators (CHAIN = && ;) ───────────────

@test "tool-reroute/cd-git: a ';' chain also rewrites to wt-git" {
    [[ "$(newcmd "$(out_for 'cd /r ; git status')")" == "wt-git /r status" ]]
}

@test "tool-reroute/cd-git: a bare '&' backgrounds cd, so it is NOT rewritten" {
    # `cd /r & git status` backgrounds the cd subshell (cwd never changes) and
    # runs git in the ORIGINAL dir; rewriting to `wt-git /r status` would change
    # which repo git inspects. `&` is not a chain separator — delegate.
    local out; out=$(out_for 'cd /r & git status')
    [[ "$out" != *wt-git* ]]
    ! denied "$out"
}

# ── press hardening: io boundaries ───────────────────────────────────────

@test "tool-reroute/io: cat with two files is NOT rewritten (single-file read only)" {
    local out; out=$(out_for 'cat a b')
    [[ "$out" != *'"command":"tilth'* ]]
    ! denied "$out"
}

@test "tool-reroute/io: the write-redirect deny names the offending target file" {
    # An in-tree (cwd-relative) target is a real repo write → deny names it.
    local out; out=$(out_for 'echo hi > scratch.txt')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$(reason "$out")" == *"scratch.txt"* ]]
}

@test "tool-reroute/io: a redirect to /dev/null is NOT denied (no tilth_write target)" {
    local out; out=$(out_for 'echo x > /dev/null')
    ! denied "$out"
}

@test "tool-reroute/io: an out-of-tree /tmp redirect is NOT denied (delegates)" {
    # /tmp scratch has no tilth_write equivalent; hard-denying it broke valid
    # non-repo writes — it must delegate, not block.
    local out; out=$(out_for 'echo hi > /tmp/zzz.txt')
    ! denied "$out"
}

# ── press hardening: fd/stderr redirects are reads, not content writes ─────
# The write-redirect deny must fire ONLY on a stdout content write (`>`, `1>`).
# An fd redirect (`2>/dev/null`, `2>&1`) writes no file content, so hard-denying
# it would block the pervasive `cat f 2>/dev/null` idiom and tell the model to
# "use tilth_write" for a command that writes nothing — the one shape that broke
# the never-hard-block contract.

@test "tool-reroute/io: a 2>/dev/null stderr redirect is a read, not a write (no deny)" {
    local out; out=$(out_for 'cat README.md 2>/dev/null')
    ! denied "$out"
    [[ "$out" != *tilth_write* ]]
}

@test "tool-reroute/io: a 2>&1 fd redirect is a read, not a write (no deny)" {
    local out; out=$(out_for 'cat README.md 2>&1')
    ! denied "$out"
    [[ "$out" != *tilth_write* ]]
}

@test "tool-reroute/io: a bare echo stderr redirect (2>err) does not deny" {
    local out; out=$(out_for 'echo x 2>err')
    ! denied "$out"
}

@test "tool-reroute/io: an explicit 1> stdout redirect still denies (real write)" {
    local out; out=$(out_for 'cat a 1>out')
    [[ "$(decision "$out")" == "deny" ]]
}

# ── press hardening: codex harness + bridge fail-open ────────────────────

# Deploy the bridge under a `.codex` root. Set `DOTFILES_HARNESS=codex` for delegation. Echo the bridge path.
deploy_codex() {
    local root="$TEST_HOME/.codex"
    deploy_reroute "$root"
    printf '%s' "$root/hooks/tool-reroute.sh"
}

@test "tool-reroute: codex harness — deny+rewrite fire; delegation never blocks" {
    local hook; hook=$(deploy_codex)
    # deny is rtk-independent → must fire identically under the codex bridge
    local dj; dj=$(jq -nc --arg w "$W" '{tool_name:"Grep",tool_input:{pattern:"foo"},cwd:$w}')
    run env DOTFILES_HARNESS=codex bash -c "printf '%s' '$dj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(decision "$output")" == "deny" ]]
    # rewrite is rtk-independent → must fire identically under the codex bridge
    local gj; gj=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"grep foo ."},cwd:$w}')
    run env DOTFILES_HARNESS=codex bash -c "printf '%s' '$gj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(newcmd "$output")" == "tilth foo --scope ." ]]
    # delegation: `rtk hook codex` errors (no codex subcommand) → fail open.
    # The documented non-goal must still be SAFE: never a deny, never a bogus
    # tilth/wt-git injection — the command just runs.
    local cj; cj=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"git status"},cwd:$w}')
    run env DOTFILES_HARNESS=codex bash -c "printf '%s' '$cj' | '$hook'"
    [ "$status" -eq 0 ]
    ! denied "$output"
    [[ "$output" != *wt-git* ]]
    [[ "$output" != *'"command":"tilth'* ]]
}

@test "tool-reroute: DOTFILES_HARNESS unset defaults to claude, even under a .codex deploy root" {
    local hook; hook=$(deploy_codex)
    # Stub rtk to echo the harness argument it received, so the assertion pins
    # the exact default value — the bridge must NOT infer codex from the
    # deploy path; only DOTFILES_HARNESS (set by the renderer) selects it.
    local stub="$TEST_HOME/rtk-stub-bin"
    mkdir -p "$stub"
    cat >"$stub/rtk" <<'RTK'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' "$2"
RTK
    chmod +x "$stub/rtk"
    local nodedir; nodedir="$(dirname "$(command -v node)")"
    local j; j=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"git status"},cwd:$w}')
    run env -u DOTFILES_HARNESS PATH="$stub:$nodedir:/usr/bin:/bin" bash -c "printf '%s' '$j' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$output" == "claude" ]]
}

@test "tool-reroute: an unrecognized DOTFILES_HARNESS value still fails open" {
    # The bridge only accepts claude|codex; an unrecognized value falls back
    # to claude rather than passing the bogus value through to rtk. Stub rtk
    # to echo the harness argument it received, pinning the exact fallback.
    local stub="$TEST_HOME/rtk-stub-bin"
    mkdir -p "$stub"
    cat >"$stub/rtk" <<'RTK'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' "$2"
RTK
    chmod +x "$stub/rtk"
    local nodedir; nodedir="$(dirname "$(command -v node)")"
    local j; j=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"git status"},cwd:$w}')
    run env DOTFILES_HARNESS=bogus PATH="$stub:$nodedir:/usr/bin:/bin" bash -c "printf '%s' '$j' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == "claude" ]]
}

@test "tool-reroute: node absent fails open (bridge command -v node guard)" {
    # Sibling of the missing-logic-file guard: with node off PATH the bridge
    # must exit 0 with no output, never block the call. Build a stub PATH that
    # carries only the bridge's coreutil needs (bash, dirname) — no node.
    local stub="$TEST_HOME/nonode-bin"
    mkdir -p "$stub"
    ln -sf "$(command -v bash)" "$stub/bash"
    ln -sf "$(command -v dirname)" "$stub/dirname"
    local j; j=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"grep x ."},cwd:$w}')
    run env -i PATH="$stub" bash -c "printf '%s' '$j' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

# ── tool-reroute/cd-strip: cd <own-cwd> && … strips the no-op cd ─────────

@test "tool-reroute/cd-strip: cd \$cwd && git status strips to git status" {
    # A strip-only hit forwards updatedInput WITHOUT permissionDecision —
    # normal permission evaluation runs on the rewritten command, per
    # Claude Code's PreToolUse contract.
    local out; out=$(out_for_rtk "cd $W && git status" "$SILENT_STUB")
    [[ "$(newcmd "$out")" == "git status" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: quoted cwd target with a semicolon separator strips" {
    local out; out=$(out_for_rtk "cd \"$W\"; echo hi" "$SILENT_STUB")
    [[ "$(newcmd "$out")" == "echo hi" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: a trailing slash on the cwd target still strips" {
    local out; out=$(out_for_rtk "cd $W/ && ls" "$SILENT_STUB")
    [[ "$(newcmd "$out")" == "ls" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: a newline separator strips" {
    local cmd; cmd=$(printf 'cd %s\necho hi' "$W")
    local out; out=$(out_for_rtk "$cmd" "$SILENT_STUB")
    [[ "$(newcmd "$out")" == "echo hi" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: an empty quoted target is left alone" {
    local out; out=$(out_for_rtk 'cd "" && ls' "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == 'cd "" && ls' ]]
}

@test "tool-reroute/cd-strip: a path with a behavior-changing .. component is left alone" {
    local out; out=$(out_for_rtk "cd $W/agents/.. && ls" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "cd $W/agents/.. && ls" ]]
}

@test "tool-reroute/cd-strip: unquoted glob and brace targets are left alone" {
    local root="$BATS_TEST_TMPDIR/expansion"
    mkdir "$root"
    local glob="$root/star*"
    local brace="$root/{star,other}"
    mkdir "$glob" "$brace"
    run node - "$REAL_DOTFILES_DIR/agents/lib/tool-reroute/cd-strip.js" "$glob" <<'NODE'
const [file, cwd] = process.argv.slice(2)
const { detect } = require(file)
process.stdout.write(JSON.stringify(detect("Bash", {command: `cd ${cwd} && printf`}, cwd)))
NODE
    [ "$status" -eq 0 ]
    [[ "$output" == "null" ]]
    run node - "$REAL_DOTFILES_DIR/agents/lib/tool-reroute/cd-strip.js" "$brace" <<'NODE'
const [file, cwd] = process.argv.slice(2)
const { detect } = require(file)
process.stdout.write(JSON.stringify(detect("Bash", {command: `cd ${cwd} && printf`}, cwd)))
NODE
    [ "$status" -eq 0 ]
    [[ "$output" == "null" ]]
}

@test "tool-reroute/cd-strip: a quoted dollar expansion target is left alone" {
    local cwd="$BATS_TEST_TMPDIR/dollar\$name"
    mkdir "$cwd"
    run node - "$REAL_DOTFILES_DIR/agents/lib/tool-reroute/cd-strip.js" "$cwd" <<'NODE'
const [file, cwd] = process.argv.slice(2)
const { detect } = require(file)
process.stdout.write(JSON.stringify(detect("Bash", {command: `cd "${cwd}" && printf`}, cwd)))
NODE
    [ "$status" -eq 0 ]
    [[ "$output" == "null" ]]
}

@test "tool-reroute/cd-strip: a subdirectory target is left alone" {
    # Not stripped: a real strip would produce updatedInput.command == "ls"
    # exactly. The recording stub proves rtk actually ran and received the
    # ORIGINAL, untouched command — a crash before delegate() would leave no
    # recorded stdin, so the negative case can't pass by accident.
    local out; out=$(out_for_rtk "cd $W/sub && ls" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "cd $W/sub && ls" ]]
}

@test "tool-reroute/cd-strip: an unrelated target is left alone" {
    local out; out=$(out_for_rtk 'cd /other && ls' "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == 'cd /other && ls' ]]
}

@test "tool-reroute/cd-strip: an || separator is left alone" {
    local out; out=$(out_for_rtk "cd $W || ls" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "cd $W || ls" ]]
}

@test "tool-reroute/cd-strip: a bare cd with no remainder is left alone" {
    local out; out=$(out_for_rtk "cd $W" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "cd $W" ]]
}

@test "tool-reroute/cd-strip: the remainder re-classifies against search" {
    local out; out=$(out_for "cd $W && grep foo .")
    [[ "$(decision "$out")" == "allow" ]]
    [[ "$(newcmd "$out")" == "$(newcmd "$(out_for 'grep foo .')")" ]]
}

@test "tool-reroute/cd-strip: the remainder re-classifies against io and denies" {
    local out; out=$(out_for "cd $W && cat > f")
    [[ "$(decision "$out")" == "deny" ]]
}

@test "tool-reroute/cd-strip: a strip-only hit with no rehit forwards updatedInput and delegates to rtk" {
    local out; out=$(out_for_rtk "cd $W && frobnicate --x" "$SILENT_STUB")
    [[ "$(newcmd "$out")" == "frobnicate --x" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: rtk's own updatedInput is forwarded verbatim (parity with plain delegate)" {
    local fixed='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk ls"},"permissionDecision":"allow"}}'
    local script; script=$(printf 'cat >"%s/rtk-in.json"\nprintf %%s '\''%s'\''' "$BATS_TEST_TMPDIR" "$fixed")
    local out; out=$(out_for_rtk "cd $W && ls" "$script")
    [[ "$out" == "$fixed" ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-in.json")" == "ls" ]]
}

@test "tool-reroute/cd-strip: a chain of no-op cds collapses in a loop" {
    local out; out=$(out_for_rtk "cd $W && cd $W && ls" "$SILENT_STUB")
    [[ "$(newcmd "$out")" == "ls" ]]
}

@test "tool-reroute/cd-strip: sibling tool_input fields survive the strip" {
    local cmd out
    cmd=$(printf 'cd %s && npm run build' "$W")
    local stub="$BATS_TEST_TMPDIR/rtk-stub-bin"
    mkdir -p "$stub"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$SILENT_STUB"; } >"$stub/rtk"
    chmod +x "$stub/rtk"
    local nodedir; nodedir="$(dirname "$(command -v node)")"
    local json; json=$(jq -nc --arg c "$cmd" --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:$c, run_in_background:true, timeout:600000, description:"build"}, cwd:$w}')
    run env PATH="$stub:$nodedir:/usr/bin:/bin" bash -c "printf '%s' '$json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    out="$output"
    local expected='{"command":"npm run build","run_in_background":true,"timeout":600000,"description":"build"}'
    [[ "$(jq -S -c '.hookSpecificOutput.updatedInput' <<<"$out")" == "$(jq -S -c . <<<"$expected")" ]]
}

@test "tool-reroute/cd-strip: an rtk deny on the stripped command is forwarded verbatim" {
    local deny='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub deny"}}'
    local script; script=$(printf 'cat >/dev/null\nprintf %%s '\''%s'\''' "$deny")
    local out; out=$(out_for_rtk "cd $W && rm -rf /" "$script")
    [[ "$(jq -S -c . <<<"$out")" == "$(jq -S -c . <<<"$deny")" ]]
}

@test "tool-reroute/cd-strip: a trailing separator with an empty remainder is not a strip" {
    local out; out=$(out_for_rtk "cd $W && " "$SILENT_STUB")
    [[ "$out" != *'updatedInput'* ]]
}

@test "tool-reroute/cd-strip: a symlink target is not matched by physical equality" {
    local link="$BATS_TEST_TMPDIR/logical-link"
    ln -s "$W" "$link"
    run node - "$REAL_DOTFILES_DIR/agents/lib/tool-reroute/cd-strip.js" "$W" "$link" <<'NODE'
const [file, cwd, target] = process.argv.slice(2)
const { detect } = require(file)
process.stdout.write(JSON.stringify(detect("Bash", {command: `cd "${cwd}" && ls`}, target)))
NODE
    [ "$status" -eq 0 ]
    [[ "$output" == "null" ]]
}

@test "tool-reroute/cd-strip: a quoted tilde is not expanded" {
    run node - "$REAL_DOTFILES_DIR/agents/lib/tool-reroute/cd-strip.js" "$HOME" <<'NODE'
const [file, cwd] = process.argv.slice(2)
const { detect } = require(file)
process.stdout.write(JSON.stringify(detect("Bash", {command: 'cd "~" && ls'}, cwd)))
NODE
    [ "$status" -eq 0 ]
    [[ "$output" == "null" ]]
}

# ── tool-reroute/cd-git: a git-only chain rewrites every segment ─────────

@test "tool-reroute/cd-git: a && chain rewrites every git segment" {
    local out; out=$(out_for 'cd /repo && git add -A && git commit -m x')
    [[ "$(newcmd "$out")" == "wt-git /repo add -A && wt-git /repo commit -m x" ]]
}

@test "tool-reroute/cd-git: a mixed ; && chain preserves each separator" {
    local out; out=$(out_for 'cd /repo && git add -A ; git status')
    [[ "$(newcmd "$out")" == "wt-git /repo add -A ; wt-git /repo status" ]]
}

@test "tool-reroute/cd-git: a non-git segment in the chain is left alone" {
    local out; out=$(out_for 'cd /repo && git add -A && yarn test')
    [[ "$out" != *"wt-git"* ]]
}

@test "tool-reroute/cd-git: assignments before later git segments delegate" {
    local cmd='cd /repo && git status && FOO=1 git status'
    local out; out=$(out_for_rtk "$cmd" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "$cmd" ]]
}

@test "tool-reroute/cd-git: sudo wrapper before later git delegates" {
    local cmd='cd /repo && git status && sudo git status'
    local out; out=$(out_for_rtk "$cmd" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "$cmd" ]]
}

@test "tool-reroute/cd-git: expansion in later git arguments delegates unchanged" {
    # shellcheck disable=SC2016
    # Intentional: preserve literal $message in the fixture.
    local cmd='cd /repo && git status && git commit -m "$message"'
    local out; out=$(out_for_rtk "$cmd" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "$cmd" ]]
}

@test "tool-reroute/cd-git: pathname expansion in later git arguments delegates unchanged" {
    local cmd out
    for cmd in \
        'cd /repo && git status && git add -n *.js' \
        'cd /repo && git status && git add -n [ab].js' \
        'cd /repo && git status && git add -n {a,b}.js' \
        'cd /repo && git status && git add -n ~/src.js' \
        'cd /repo && git status && git hash-object --stdin < file' \
        'cd /repo && git status # note'; do
        out=$(out_for_rtk "$cmd" "$(record_stub "$BATS_TEST_TMPDIR")")
        [[ "$out" != *'updatedInput'* ]]
        [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "$cmd" ]]
    done
}

@test "tool-reroute/cd-git: unterminated later git quotes delegate unchanged" {
    local cmd="cd /repo && git status && git commit -m 'oops"
    local out; out=$(out_for_rtk_safe "$cmd" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "$cmd" ]]

    cmd='cd /repo && git status && git commit -m "oops'
    out=$(out_for_rtk_safe "$cmd" "$(record_stub "$BATS_TEST_TMPDIR")")
    [[ "$out" != *'updatedInput'* ]]
    [[ "$(jq -r '.tool_input.command' "$BATS_TEST_TMPDIR/rtk-stdin.json")" == "$cmd" ]]
}

# ── tool-reroute/log: rewrite/deny decisions append to decisions.jsonl ───

@test "tool-reroute/log: a rewrite appends one decision record" {
    out_for 'cd /repo && git status' >/dev/null
    local log="$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl"
    [ "$(wc -l <"$log")" -eq 1 ]
    [[ "$(jq -r .module <"$log")" == "cd-git" ]]
    [[ "$(jq -r .action <"$log")" == "rewrite" ]]
    [[ "$(jq -r .rewrite <"$log")" == "wt-git /repo status" ]]
    [[ "$(jq -r .command <"$log")" == "cd /repo && git status" ]]
}

@test "tool-reroute/log: a delegated command logs nothing" {
    out_for 'echo plain' >/dev/null
    [ ! -e "$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl" ]
}

@test "tool-reroute/log: a deny appends one decision record" {
    out_for 'cat > f' >/dev/null
    local log="$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl"
    [ "$(wc -l <"$log")" -eq 1 ]
    [[ "$(jq -r .action <"$log")" == "deny" ]]
    [[ "$(jq -r .module <"$log")" == "io" ]]
}

@test "tool-reroute/log: a strip-only hit logs action strip, module cd-strip" {
    out_for_rtk "cd $W && frobnicate --x" "$SILENT_STUB" >/dev/null
    local log="$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl"
    [ "$(wc -l <"$log")" -eq 1 ]
    [[ "$(jq -r .action <"$log")" == "strip" ]]
    [[ "$(jq -r .module <"$log")" == "cd-strip" ]]
}

@test "tool-reroute/log: Grep records a bounded sanitized pattern" {
    local secret="TOKEN=grep-secret"
    local out; out=$(out_for_input Grep "$(jq -nc --arg p "$secret" '{pattern:$p}')")
    [[ "$(decision "$out")" == "deny" ]]
    local log="$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl"
    [[ "$(jq -r .pattern <"$log")" == "TOKEN=<redacted>" ]]
    ! grep -Fq "$secret" "$log"
    [ "$(jq -r '.reason | length' <"$log")" -le 500 ]
}

@test "jsonl-log: shared persistence redacts lowercase, quoted, and token arguments before truncation" {
    local dir="$BATS_TEST_TMPDIR/jsonl-redact"
    run node - "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir" <<'NODE'
const [file, dir] = process.argv.slice(2)
const { appendJsonl, scrubSecrets } = require(file)
const value = `token="quoted-secret" --token argument-secret ${"x".repeat(490)} TOKEN=tail-secret`
appendJsonl(dir, "f.jsonl", { value }, 5000)
process.stdout.write(scrubSecrets(value))
NODE
    [ "$status" -eq 0 ]
    [[ "$output" != *quoted-secret* ]]
    [[ "$output" != *argument-secret* ]]
    [[ "$output" != *tail-secret* ]]
    ! grep -Fq quoted-secret "$BATS_TEST_TMPDIR/jsonl-redact/f.jsonl"
    ! grep -Fq argument-secret "$BATS_TEST_TMPDIR/jsonl-redact/f.jsonl"
    ! grep -Fq tail-secret "$BATS_TEST_TMPDIR/jsonl-redact/f.jsonl"
}

@test "jsonl-log: existing broad log directory fails closed" {
    local dir="$BATS_TEST_TMPDIR/jsonl-broad"
    mkdir "$dir"
    chmod 755 "$dir"
    run node - "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir" <<'NODE'
const [file, dir] = process.argv.slice(2)
require(file).appendJsonl(dir, "f.jsonl", { value: "x" }, 1000)
NODE
    [ "$status" -eq 0 ]
    [ ! -e "$dir/f.jsonl" ]
}

@test "jsonl-log: existing broad log file fails closed" {
    local dir="$BATS_TEST_TMPDIR/jsonl-file"
    mkdir "$dir"
    chmod 700 "$dir"
    local log="$dir/f.jsonl"
    printf '%s\n' '{"old":1}' >"$log"
    chmod 644 "$log"
    node - "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir" <<'NODE'
const [file, dir] = process.argv.slice(2)
require(file).appendJsonl(dir, "f.jsonl", { value: "new" }, 1000)
NODE
    [[ "$(wc -l <"$log")" -eq 1 ]]
    ! grep -Fq '"value":"new"' "$log"
}

@test "jsonl-log: symlink log file fails closed" {
    local dir="$BATS_TEST_TMPDIR/jsonl-symlink"
    mkdir "$dir"
    chmod 700 "$dir"
    local target="$BATS_TEST_TMPDIR/sentinel"
    printf sentinel >"$target"
    ln -s "$target" "$dir/f.jsonl"
    node - "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir" <<'NODE'
const [file, dir] = process.argv.slice(2)
require(file).appendJsonl(dir, "f.jsonl", { value: "new" }, 1000)
NODE
    [[ "$(cat "$target")" == sentinel ]]
}

@test "jsonl-log: symlink swap before open does not follow target" {
    local dir="$BATS_TEST_TMPDIR/jsonl-race"
    mkdir "$dir"
    chmod 700 "$dir"
    local target="$BATS_TEST_TMPDIR/race-sentinel"
    printf sentinel >"$target"
    local log="$dir/f.jsonl"
    printf '%s\n' '{"old":1}' >"$log"
    chmod 600 "$log"
    run node - "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir" "$target" <<'NODE'
const fs = require('fs')
const path = require('path')
const [file, dir, target] = process.argv.slice(2)
const full = path.join(dir, 'f.jsonl')
const originalOpenSync = fs.openSync
let swapped = false
fs.openSync = (name, flags, mode) => {
  if (!swapped && name === full) {
    swapped = true
    fs.unlinkSync(name)
    fs.symlinkSync(target, name)
  }
  return originalOpenSync(name, flags, mode)
}
require(file).appendJsonl(dir, 'f.jsonl', { value: 'new' }, 1000)
if (!swapped) throw new Error('open race was not exercised')
NODE
    [ "$status" -eq 0 ]
    [[ "$(cat "$target")" == sentinel ]]
    [ -L "$log" ]
}

@test "jsonl-log: FIFO path fails open without blocking" {
    local dir="$BATS_TEST_TMPDIR/jsonl-fifo"
    mkdir "$dir"
    chmod 700 "$dir"
    local fifo="$dir/f.jsonl"
    mkfifo "$fifo"
    chmod 600 "$fifo"
    run node - "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir" <<'NODE'
const { spawn } = require('child_process')
const [file, dir] = process.argv.slice(2)
const child = spawn(process.execPath, [
  '-e',
  'require(process.argv[1]).appendJsonl(process.argv[2], "f.jsonl", { value: "new" }, 1000)',
  file,
  dir,
], { stdio: 'ignore' })
const timer = setTimeout(() => {
  child.kill('SIGKILL')
  process.exit(124)
}, 1000)
child.once('error', () => {
  clearTimeout(timer)
  process.exit(1)
})
child.once('exit', (code, signal) => {
  clearTimeout(timer)
  process.exit(code === 0 && signal === null ? 0 : 1)
})
NODE
    [ "$status" -eq 0 ]
    [ -p "$fifo" ]
}

# ── jsonl-log: shared append/rotate helper ────────────────────────────────

@test "jsonl-log: appendJsonl rotates to .1 past maxBytes" {
    local dir="$BATS_TEST_TMPDIR/jsonl-rotate"
    node -e '
        const { appendJsonl } = require(process.argv[1]);
        const dir = process.argv[2];
        appendJsonl(dir, "f.jsonl", { a: "x".repeat(50) }, 10);
        appendJsonl(dir, "f.jsonl", { a: "y" }, 10);
    ' "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir"
    [ -f "$dir/f.jsonl.1" ]
    [ -f "$dir/f.jsonl" ]
    [[ "$(jq -r .a <"$dir/f.jsonl")" == "y" ]]
}

@test "jsonl-log: an unwritable dir (a file at the dir path) fails open, no throw" {
    local path="$BATS_TEST_TMPDIR/not-a-dir"
    printf 'x' >"$path"
    run node -e '
        const { appendJsonl } = require(process.argv[1]);
        appendJsonl(process.argv[2], "f.jsonl", { a: 1 }, 1000);
        console.log("ok");
    ' "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$path"
    [ "$status" -eq 0 ]
    [[ "$output" == "ok" ]]
}
