#!/usr/bin/env bats
# Tests for the tool-reroute PreToolUse hook (harness-agnostic).
#   agents/hooks/tool-reroute.sh  — bash bridge (self-locating, overrideable harness)
#   agents/lib/tool-reroute.js    — dispatcher (native → search → cd-strip → cd-git → io)
#   agents/lib/tool-reroute/{shell,native,search,cd-strip,cd-git,io}.js — lexer + modules
#
# WHY: tilth owns file reads, writes, and searches on Claude and Codex. The hook
# DENIES a built-in or shell call that reads, searches, or writes files and names
# the tilth MCP call to make instead; a hook's updatedInput cannot turn a Bash
# call into an MCP call, so there is no rewrite target. Claude also removes
# Write/Edit/Grep/Glob from context through permissions.deny, so the
# model does not retry a tool it cannot see. Calls that read no file (pipe
# filters, here-docs, `tail -f`, /proc) run unchanged, and the passthrough and
# fail-open tests encode that a non-file or broken hook never blocks a call.

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

# Like out_for, but passes the JSON as an argv (not interpolated into -c) so a
# cmd containing a literal single/double quote can't break the shell string.
out_for_safe() {
    local cmd="$1" json
    json=$(jq -nc --arg c "$cmd" --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:$c}, cwd:$w}')
    # shellcheck disable=SC2016  # $1/$2 expand inside the inner bash, by design
    run env bash -c 'printf "%s" "$1" | "$2"' bash "$json" "$DEPLOY/hooks/tool-reroute.sh"
    [ "$status" -eq 0 ]
    printf '%s' "$output"
}

decision() { jq -r '.hookSpecificOutput.permissionDecision' <<<"$1"; }
newcmd()   { jq -r '.hookSpecificOutput.updatedInput.command' <<<"$1"; }
reason()   { jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$1"; }
no_permission_decision() { jq -e '.hookSpecificOutput | has("permissionDecision") | not' <<<"$1" >/dev/null; }

# ── tool-reroute/search: file searches → tilth_search (deny) ───────────────

@test "tool-reroute/search: grep on a path denies and names tilth_search" {
    local out; out=$(out_for 'grep foo src/')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$(reason "$out")" == *tilth_search* ]]
    [[ "$(reason "$out")" == *src/* ]]
    [[ "$(reason "$out")" == *'"foo"'* ]]
}

@test "tool-reroute/search: recursive searches with no path deny (they read the cwd)" {
    local cmd
    for cmd in 'grep -rn foo' 'rg foo' 'ag baz' 'ack qux' 'egrep -R x'; do
        [[ "$(decision "$(out_for "$cmd")")" == "deny" ]] || { echo "expected deny: $cmd" >&2; return 1; }
    done
}

@test "tool-reroute/search: flags and their values do not hide the path operand" {
    local cmd
    for cmd in 'grep -i Foo .' 'grep -l foo .' 'grep --include=*.js foo .' 'grep -A 3 foo f.txt' \
        'rg -t rust foo' 'rg -g "*.rs" foo src' 'grep -e foo -e bar f.txt' 'grep "a.*b" src/'; do
        [[ "$(decision "$(out_for_safe "$cmd")")" == "deny" ]] || { echo "expected deny: $cmd" >&2; return 1; }
    done
}

@test "tool-reroute/search: a file fed through an input redirect denies" {
    [[ "$(decision "$(out_for 'grep foo < f.txt')")" == "deny" ]]
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
    # 'grep' lives inside a string literal, not the command word.
    local out; out=$(out_for 'echo "run grep later"')
    [[ -z "$out" ]]
}

# ── tool-reroute/native: built-in file tools → tilth (deny) ─────────────────

@test "tool-reroute/native: Read on a text file denies and names tilth_read" {
    local out; out=$(out_for_input Read '{"file_path":"/repo/src/main.rs"}')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$(reason "$out")" == *tilth_read* ]]
    [[ "$(reason "$out")" == */repo/src/main.rs* ]]
}

@test "tool-reroute/native: Read on an image, PDF, or notebook runs unchanged" {
    local f
    for f in shot.png photo.JPG anim.gif diagram.webp spec.pdf nb.ipynb; do
        [[ -z "$(out_for_input Read "{\"file_path\":\"/tmp/$f\"}")" ]] || { echo "expected pass: $f" >&2; return 1; }
    done
}

@test "tool-reroute/native: Write, Edit, MultiEdit, and Codex apply_patch deny and name tilth_write" {
    local tool out
    for tool in Write Edit MultiEdit apply_patch; do
        out=$(out_for_input "$tool" '{"file_path":"a.txt","command":"*** Begin Patch"}')
        [[ "$(decision "$out")" == "deny" ]] || { echo "expected deny: $tool" >&2; return 1; }
        [[ "$(reason "$out")" == *tilth_write* ]]
    done
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

# ── tool-reroute/io: shell reads → tilth_read; writes → tilth_write (deny) ──

@test "tool-reroute/io: a shell file read denies and names tilth_read" {
    local out; out=$(out_for 'cat README.md')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$(reason "$out")" == *tilth_read* ]]
    [[ "$(reason "$out")" == *README.md* ]]
}

@test "tool-reroute/io: every reader with a file operand denies" {
    local cmd
    # shellcheck disable=SC2016  # literal commands for the hook; nothing expands here.
    for cmd in 'cat -n file.txt' 'head -n 5 f' 'head -5 f' 'tail -50 /tmp/x.log' 'sed -n 1,20p f' \
        "awk '{print \$1}' f" 'nl f' 'less f' 'bat f' 'tac f' 'x=$(cat f)' 'wc -l a && cat b'; do
        [[ "$(decision "$(out_for_safe "$cmd")")" == "deny" ]] || { echo "expected deny: $cmd" >&2; return 1; }
    done
}

@test "tool-reroute/io: sed -i denies and names tilth_write" {
    local out; out=$(out_for 'sed -i s/a/b/ f.txt')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$(reason "$out")" == *tilth_write* ]]
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

# ── tool-reroute/passthrough: non-reroute Bash runs unchanged ────────────

@test "tool-reroute/passthrough: plain git is not touched (exit 0, empty)" {
    # No module owns `git status` — it runs unchanged: exit 0, no stdout.
    local out; out=$(out_for 'git status')
    [[ -z "$out" ]]
}

@test "tool-reroute/passthrough: plain git inside a Claude worktree is not touched" {
    # Claude Code's Agent tool (`isolation: "worktree"`) creates worktrees under
    # `<repo>/.claude/worktrees/agent-*`. Plain passthrough is the default
    # everywhere, so a command inside one of these worktrees needs no special
    # case.
    W="$BATS_TEST_TMPDIR/.claude/worktrees/agent-x"
    mkdir -p "$W"
    local out; out=$(out_for 'git status')
    [[ -z "$out" ]]
    [ ! -e "$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl" ]
}

# ── tool-reroute: protocol / fail-open ───────────────────────────────────

@test "tool-reroute: rewrite payload is a valid PreToolUse allow + updatedInput" {
    local out; out=$(out_for 'cd /r && git status')
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
    local out; out=$(out_for_input mcp__tilth__tilth_read '{"paths":["/x"]}')
    [[ -z "$out" ]]
}

# ── deploy wiring ────────────────────────────────────────────────────────

@test "tool-reroute: registry registers tool-reroute for claude and codex file tools" {
    local reg="$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"
    [[ "$(yq -r '.hooks.tool-reroute.event' "$reg")" == "PreToolUse" ]]
    [[ "$(yq -r '.hooks.tool-reroute.script' "$reg")" == "agents/hooks/tool-reroute.sh" ]]
    [[ "$(yq -r '.hooks.tool-reroute.matcher' "$reg")" == "Bash|Read|Write|Edit|MultiEdit|Grep|Glob|apply_patch" ]]
    [[ "$(yq -r '.hooks.tool-reroute.harnesses | join(",")' "$reg")" == "claude,codex" ]]
    [[ "$(yq -r '.hooks.tool-reroute.shared_assets[0]' "$reg")" == "agents/lib/tool-reroute.js" ]]
    # every module file the dispatcher requires is deployed
    local mod
    for mod in "$MOD_DIR"/*.js; do
        yq -e ".hooks.tool-reroute.shared_assets[] | select(. == \"agents/lib/tool-reroute/$(basename "$mod")\")" "$reg" >/dev/null \
            || { echo "undeployed module: $mod" >&2; return 1; }
    done
}

@test "tool-reroute: live Claude settings deny the write and search tools and route through the hook" {
    local data="$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    local reg="$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"
    local tool
    for tool in Edit Glob Grep Write; do
        yq -e ".claude.permissions.deny[] | select(. == \"$tool\")" "$data" >/dev/null || { echo "not denied: $tool" >&2; return 1; }
        if yq -e ".claude.permissions.allow[] | select(. == \"$tool\")" "$data" >/dev/null; then
            echo "still allowed: $tool" >&2; return 1
        fi
    done
    # Read stays reachable for images, PDFs, and notebooks; the hook gates text reads.
    if yq -e '.claude.permissions.deny[] | select(. == "Read")' "$data" >/dev/null; then
        echo "Read must stay reachable for media" >&2; return 1
    fi
    # The settings.json matcher mirrors the registry matcher.
    [[ "$(yq -r '.claude.hooks.PreToolUse[] | select(.hooks[0].command | test("tool-reroute")) | .matcher' "$data")" \
        == "$(yq -r '.hooks.tool-reroute.matcher' "$reg")" ]]
}

@test "tool-reroute: permissions profile leaves file tools to the hook" {
    local prof="$REAL_DOTFILES_DIR/profiles/_permissions/profile.yaml"
    run yq -e '.settings.permissions_allow[] | select(. == "Bash(tilth:*)")' "$prof"
    [ "$status" -eq 0 ]
    # The profile also lowers onto Cursor and Copilot, which keep native file
    # tools, so it carries no static deny for them.
    run yq -e '.settings.permissions_deny[] | select(. == "Grep" or . == "Glob" or . == "Bash(grep:*)")' "$prof"
    [ "$status" -ne 0 ]
    # the rg allow stays removed (a stray rg prompts rather than running unfiltered)
    run yq -e '.settings.permissions_allow[] | select(. == "Bash(rg:*)")' "$prof"
    [ "$status" -ne 0 ]
}

# ── press hardening: the passthrough contract ─────────────────────────────
# A deny is correct only when the call reads, searches, or writes a file that
# tilth can serve. A command that filters a stream, reads a kernel interface,
# follows a live log, or lists files must run unchanged; denying it would send
# the model to a tilth call that cannot do the job.

denied() { [[ "$1" == *'"permissionDecision":"deny"'* ]]; }

@test "tool-reroute: commands that read no file run unchanged" {
    local cmd out
    # shellcheck disable=SC2016  # literal commands for the hook; nothing expands here.
    for cmd in \
        'git log | grep fix' \
        'git diff | head -20' \
        'echo x | rg foo' \
        'ps aux | awk "{print \$1}"' \
        'git show HEAD | sed s/a/b/' \
        'grep foo' \
        'tail -f /tmp/x.log' \
        'cat /proc/cpuinfo' \
        'head -c 16 /dev/urandom' \
        'rg --files' \
        'ag -g foo' \
        'git grep foo' \
        'find . -name foo.js' \
        'find . -size +100M' \
        'ls -la' \
        'cd /r && gh pr list'; do
        out=$(out_for_safe "$cmd")
        if denied "$out"; then
            echo "must pass, not DENY: $cmd -> $out" >&2
            return 1
        fi
    done
}

@test "tool-reroute: here-doc bodies are not parsed as commands" {
    local cmd out
    cmd=$'git commit -F - <<\'EOF\'\ngrep foo bar\ncat secret.txt\nEOF'
    out=$(out_for_safe "$cmd")
    if denied "$out"; then echo "body parsed as a command: $out" >&2; return 1; fi
    cmd=$'cat <<-EOF > /tmp/note\n\tsed -n 1p f\n\tEOF\ngit status'
    out=$(out_for_safe "$cmd")
    if denied "$out"; then echo "<<- body parsed as a command: $out" >&2; return 1; fi
    # A command after the closed body is still classified.
    cmd=$'git commit -F - <<EOF\nmsg\nEOF\ncat README.md'
    [[ "$(decision "$(out_for_safe "$cmd")")" == "deny" ]]
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

@test "tool-reroute/io: a read of several files names every file" {
    local out; out=$(out_for 'cat a b')
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$(reason "$out")" == *'"a", "b"'* ]]
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
# An fd redirect (`2>/dev/null`, `2>&1`) writes no file content, so a read
# with one denies as a read (tilth_read), never as a write (tilth_write).

@test "tool-reroute/io: a 2>/dev/null stderr redirect is a read, not a write" {
    local out; out=$(out_for 'cat README.md 2>/dev/null')
    [[ "$(reason "$out")" == *tilth_read* ]]
    [[ "$out" != *tilth_write* ]]
}

@test "tool-reroute/io: a 2>&1 fd redirect is a read, not a write" {
    local out; out=$(out_for 'cat README.md 2>&1')
    [[ "$(reason "$out")" == *tilth_read* ]]
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

@test "tool-reroute: codex harness — deny+rewrite fire; non-reroute never blocks" {
    local hook; hook=$(deploy_codex)
    # apply_patch denies under the codex bridge
    local pj; pj=$(jq -nc --arg w "$W" '{tool_name:"apply_patch",tool_input:{command:"*** Begin Patch"},cwd:$w}')
    run env DOTFILES_HARNESS=codex bash -c "printf '%s' '$pj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(decision "$output")" == "deny" ]]
    [[ "$(reason "$output")" == *tilth_write* ]]
    # a shell file read denies under the codex bridge
    local rj; rj=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"sed -n 1,80p README.md"},cwd:$w}')
    run env DOTFILES_HARNESS=codex bash -c "printf '%s' '$rj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(decision "$output")" == "deny" ]]
    # rewrite fires identically under the codex bridge
    local gj; gj=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"cd /r && git status"},cwd:$w}')
    run env DOTFILES_HARNESS=codex bash -c "printf '%s' '$gj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(newcmd "$output")" == "wt-git /r status" ]]
    # a non-reroute command under the codex bridge just runs, unchanged.
    local cj; cj=$(jq -nc --arg w "$W" '{tool_name:"Bash",tool_input:{command:"git status"},cwd:$w}')
    run env DOTFILES_HARNESS=codex bash -c "printf '%s' '$cj' | '$hook'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "tool-reroute: DOTFILES_HARNESS unset defaults to claude, even under a .codex deploy root" {
    local hook; hook=$(deploy_codex)
    # The bridge must NOT infer codex from the deploy path; only
    # DOTFILES_HARNESS (set by the renderer) selects it. A deny logs the
    # harness the bridge resolved.
    local j; j=$(jq -nc --arg w "$W" '{tool_name:"Grep",tool_input:{pattern:"foo"},cwd:$w}')
    run env -u DOTFILES_HARNESS bash -c "printf '%s' '$j' | '$hook'"
    [ "$status" -eq 0 ]
    [[ "$(jq -r .harness "$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl")" == "claude" ]]
}

@test "tool-reroute: an unrecognized DOTFILES_HARNESS value still fails open" {
    # The bridge only accepts claude|codex; an unrecognized value falls back
    # to claude rather than passing the bogus value through. A deny logs the
    # harness the bridge resolved.
    local j; j=$(jq -nc --arg w "$W" '{tool_name:"Grep",tool_input:{pattern:"foo"},cwd:$w}')
    run env DOTFILES_HARNESS=bogus bash -c "printf '%s' '$j' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    [[ "$(jq -r .harness "$CLAUDE_TOOL_REROUTE_LOG_DIR/decisions.jsonl")" == "claude" ]]
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
    local out; out=$(out_for "cd $W && git status")
    [[ "$(newcmd "$out")" == "git status" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: quoted cwd target with a semicolon separator strips" {
    local out; out=$(out_for "cd \"$W\"; echo hi")
    [[ "$(newcmd "$out")" == "echo hi" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: a trailing slash on the cwd target still strips" {
    local out; out=$(out_for "cd $W/ && ls")
    [[ "$(newcmd "$out")" == "ls" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: a newline separator strips" {
    local cmd; cmd=$(printf 'cd %s\necho hi' "$W")
    local out; out=$(out_for "$cmd")
    [[ "$(newcmd "$out")" == "echo hi" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: an empty quoted target is left alone" {
    local out; out=$(out_for 'cd "" && ls')
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
}

@test "tool-reroute/cd-strip: a path with a behavior-changing .. component is left alone" {
    local out; out=$(out_for "cd $W/agents/.. && ls")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
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
    # exactly. No module matches, so the command runs unchanged (empty output).
    local out; out=$(out_for "cd $W/sub && ls")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
}

@test "tool-reroute/cd-strip: an unrelated target is left alone" {
    local out; out=$(out_for 'cd /other && ls')
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
}

@test "tool-reroute/cd-strip: an || separator is left alone" {
    local out; out=$(out_for "cd $W || ls")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
}

@test "tool-reroute/cd-strip: a bare cd with no remainder is left alone" {
    local out; out=$(out_for "cd $W")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
}

@test "tool-reroute/cd-strip: the remainder re-classifies against search" {
    local out; out=$(out_for "cd $W && grep foo .")
    [[ "$(decision "$out")" == "deny" ]]
    [[ "$(reason "$out")" == *tilth_search* ]]
}

@test "tool-reroute/cd-strip: the remainder re-classifies against io and denies" {
    local out; out=$(out_for "cd $W && cat > f")
    [[ "$(decision "$out")" == "deny" ]]
}

@test "tool-reroute/cd-strip: a strip-only hit with no rehit forwards updatedInput" {
    local out; out=$(out_for "cd $W && frobnicate --x")
    [[ "$(newcmd "$out")" == "frobnicate --x" ]]
    no_permission_decision "$out"
}

@test "tool-reroute/cd-strip: a chain of no-op cds collapses in a loop" {
    local out; out=$(out_for "cd $W && cd $W && ls")
    [[ "$(newcmd "$out")" == "ls" ]]
}

@test "tool-reroute/cd-strip: sibling tool_input fields survive the strip" {
    local cmd out
    cmd=$(printf 'cd %s && npm run build' "$W")
    local json; json=$(jq -nc --arg c "$cmd" --arg w "$W" \
        '{tool_name:"Bash", tool_input:{command:$c, run_in_background:true, timeout:600000, description:"build"}, cwd:$w}')
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/tool-reroute.sh'"
    [ "$status" -eq 0 ]
    out="$output"
    local expected='{"command":"npm run build","run_in_background":true,"timeout":600000,"description":"build"}'
    [[ "$(jq -S -c '.hookSpecificOutput.updatedInput' <<<"$out")" == "$(jq -S -c . <<<"$expected")" ]]
}

@test "tool-reroute/cd-strip: a trailing separator with an empty remainder is not a strip" {
    local out; out=$(out_for "cd $W && ")
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
    local out; out=$(out_for "$cmd")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
}

@test "tool-reroute/cd-git: sudo wrapper before later git delegates" {
    local cmd='cd /repo && git status && sudo git status'
    local out; out=$(out_for "$cmd")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
}

@test "tool-reroute/cd-git: expansion in later git arguments delegates unchanged" {
    # shellcheck disable=SC2016
    # Intentional: preserve literal $message in the fixture.
    local cmd='cd /repo && git status && git commit -m "$message"'
    local out; out=$(out_for "$cmd")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
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
        out=$(out_for "$cmd")
        [[ "$out" != *'updatedInput'* ]]
        [[ -z "$out" ]]
    done
}

@test "tool-reroute/cd-git: unterminated later git quotes delegate unchanged" {
    local cmd="cd /repo && git status && git commit -m 'oops"
    local out; out=$(out_for_safe "$cmd")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]

    cmd='cd /repo && git status && git commit -m "oops'
    out=$(out_for_safe "$cmd")
    [[ "$out" != *'updatedInput'* ]]
    [[ -z "$out" ]]
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
    out_for "cd $W && frobnicate --x" >/dev/null
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

@test "jsonl-log: unsafe replacement after rotation fails closed" {
    local dir="$BATS_TEST_TMPDIR/jsonl-rotate-unsafe"
    mkdir "$dir"
    chmod 700 "$dir"
    local log="$dir/f.jsonl"
    printf '%s\n' '{"old":"xxxxxxxxxxxxxxxx"}' >"$log"
    chmod 600 "$log"
    local target="$BATS_TEST_TMPDIR/rotate-sentinel"
    printf sentinel >"$target"
    run node - "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$dir" "$target" <<'NODE'
const fs = require('fs')
const path = require('path')
const [file, dir, target] = process.argv.slice(2)
const full = path.join(dir, 'f.jsonl')
const originalRenameSync = fs.renameSync
fs.renameSync = (from, to) => {
  originalRenameSync(from, to)
  fs.symlinkSync(target, from)
}
require(file).appendJsonl(dir, 'f.jsonl', { value: 'new' }, 10)
NODE
    [ "$status" -eq 0 ]
    [ -f "$dir/f.jsonl.1" ]
    [ -L "$log" ]
    [[ "$(cat "$target")" == sentinel ]]
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
