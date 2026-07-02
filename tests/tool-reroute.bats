#!/usr/bin/env bats
# Tests for the tool-reroute PreToolUse hook (harness-agnostic).
#   agents/hooks/tool-reroute.sh  — bash bridge (self-locating, claude/codex)
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

setup() {
    setup_test_env
    # Mirror the deployed layout: <root>/hooks/<bridge> + <root>/lib/<logic>
    # + <root>/lib/tool-reroute/<modules>. <root> ends in `.claude` so the
    # bridge's path-based harness detection resolves to claude (→ rtk hook claude).
    DEPLOY="$TEST_HOME/.claude"
    mkdir -p "$DEPLOY/hooks" "$DEPLOY/lib/tool-reroute"
    cp "$HOOK_SH" "$DEPLOY/hooks/tool-reroute.sh"
    cp "$HOOK_JS" "$DEPLOY/lib/tool-reroute.js"
    cp "$MOD_DIR"/*.js "$DEPLOY/lib/tool-reroute/"
    chmod +x "$DEPLOY/hooks/tool-reroute.sh"
    W="$REAL_DOTFILES_DIR"   # a real dir to stand in as the event cwd
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

# Deploy the bridge under a `.codex`-suffixed root so the bridge's path-based
# detection resolves HARNESS=codex (→ `rtk hook codex`). Echoes the bridge path.
deploy_codex() {
    local root="$TEST_HOME/.codex"
    mkdir -p "$root/hooks" "$root/lib/tool-reroute"
    cp "$HOOK_SH" "$root/hooks/tool-reroute.sh"
    cp "$HOOK_JS" "$root/lib/tool-reroute.js"
    cp "$MOD_DIR"/*.js "$root/lib/tool-reroute/"
    chmod +x "$root/hooks/tool-reroute.sh"
    printf '%s' "$root/hooks/tool-reroute.sh"
}

@test "tool-reroute: codex harness — deny+rewrite fire; delegation never blocks" {
    local hook; hook=$(deploy_codex)
    # deny is rtk-independent → must fire identically under the codex bridge
    local dj; dj=$(jq -nc --arg w "$W" '{tool_name:"Grep",tool_input:{pattern:"foo"},cwd:$w}')
    run bash -c "printf '%s' '$dj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(decision "$output")" == "deny" ]]
    # rewrite is rtk-independent → must fire identically under the codex bridge
    local gj; gj=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"grep foo ."},cwd:$w}')
    run bash -c "printf '%s' '$gj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(newcmd "$output")" == "tilth foo --scope ." ]]
    # delegation: `rtk hook codex` errors (no codex subcommand) → fail open.
    # The documented non-goal must still be SAFE: never a deny, never a bogus
    # tilth/wt-git injection — the command just runs.
    local cj; cj=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"git status"},cwd:$w}')
    run bash -c "printf '%s' '$cj' | '$hook'"
    [ "$status" -eq 0 ]
    ! denied "$output"
    [[ "$output" != *wt-git* ]]
    [[ "$output" != *'"command":"tilth'* ]]
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
