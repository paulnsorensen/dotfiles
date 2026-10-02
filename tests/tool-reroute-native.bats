#!/usr/bin/env bats
# Tests for the native module and dispatcher hardening of the tool-reroute hook.
#   agents/lib/tool-reroute/native.js — built-in tool denies, Claude plan/memory
#                                       pass, Codex tilth_write out-of-tree block
#   agents/lib/tool-reroute.js        — kill switch, strip output, null stdin
#   agents/lib/jsonl-log.js           — bounded secret scrubbing
#
# WHY: Claude plan mode and auto-memory write only through the built-in Write
# and Edit tools, so those paths must pass. Codex approves tilth_write with no
# prompt and tilth_write takes absolute paths, so the hook must block writes
# outside the checkout. A hook that stalls past its timeout loses its deny, so
# a huge command must finish fast.

load test_helper

HOOK_SH="$REAL_DOTFILES_DIR/agents/hooks/tool-reroute.sh"
HOOK_JS="$REAL_DOTFILES_DIR/agents/lib/tool-reroute.js"
MOD_DIR="$REAL_DOTFILES_DIR/agents/lib/tool-reroute"

setup() {
    setup_test_env
    DEPLOY="$TEST_HOME/.claude"
    mkdir -p "$DEPLOY/hooks" "$DEPLOY/lib/tool-reroute"
    cp "$HOOK_SH" "$DEPLOY/hooks/tool-reroute.sh"
    cp "$HOOK_JS" "$DEPLOY/lib/tool-reroute.js"
    cp "$MOD_DIR"/*.js "$DEPLOY/lib/tool-reroute/"
    cp "$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js" "$DEPLOY/lib/jsonl-log.js"
    chmod +x "$DEPLOY/hooks/tool-reroute.sh"
    export CLAUDE_TOOL_REROUTE_LOG_DIR="$BATS_TEST_TMPDIR/reroute-log"
    # Keep the scratch roots away from the sandbox HOME so denials are testable.
    export TMPDIR="/var/empty/none"
    unset DOTFILES_WRITE_GUARD_ALLOW DOTFILES_TOOL_REROUTE
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
}

teardown() { teardown_test_env; }

# hook <harness> <tool> <tool_input json> [cwd] — raw stdout; status must be 0.
hook() {
    local harness="$1" tool="$2" input="$3" cwd="${4:-$REPO}" json
    json=$(jq -nc --arg t "$tool" --argjson i "$input" --arg w "$cwd" \
        '{tool_name:$t, tool_input:$i, cwd:$w}')
    # shellcheck disable=SC2016  # $1/$2 expand inside the inner bash, by design
    run env DOTFILES_HARNESS="$harness" bash -c 'printf "%s" "$1" | "$2"' bash "$json" "$DEPLOY/hooks/tool-reroute.sh"
    [ "$status" -eq 0 ]
}

decision() { jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$output"; }
reason()   { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$output"; }

tilth_write_input() {
    jq -nc --arg p "$1" '{cwd:"/", edits:[{path:$p, ops:[{op:"create_file", content:"x"}]}]}'
}

# ── Claude: plan files and auto-memory pass ───────────────────────────────

@test "native: Write to the Claude plan file passes" {
    hook claude Write "$(jq -nc --arg p "$HOME/.claude/plans/x.md" '{file_path:$p, content:"x"}')"
    [ -z "$output" ]
}

@test "native: Edit and MultiEdit on auto-memory pass" {
    local p="$HOME/.claude/projects/-Users-me-repo/memory/note.md" tool
    for tool in Edit MultiEdit Write; do
        hook claude "$tool" "$(jq -nc --arg p "$p" '{file_path:$p}')"
        [ -z "$output" ] || { echo "not passed: $tool" >&2; return 1; }
    done
}

@test "native: Read of a plan file passes" {
    hook claude Read "$(jq -nc --arg p "$HOME/.claude/plans/x.md" '{file_path:$p}')"
    [ -z "$output" ]
}

@test "native: Write to a repo file still denies" {
    hook claude Write "$(jq -nc --arg p "$REPO/a.txt" '{file_path:$p, content:"x"}')"
    [ "$(decision)" = "deny" ]
    [[ "$(reason)" == *tilth_write* ]]
}

@test "native: dot-dot escape from the plans dir denies" {
    hook claude Write "$(jq -nc --arg p "$HOME/.claude/plans/../settings.json" '{file_path:$p}')"
    [ "$(decision)" = "deny" ]
}

@test "native: a path that only resembles memory denies" {
    hook claude Write "$(jq -nc --arg p "$HOME/.claude/projects/p/notmemory/x.md" '{file_path:$p}')"
    [ "$(decision)" = "deny" ]
    hook claude Write "$(jq -nc --arg p "$HOME/.claude/plans-evil/x.md" '{file_path:$p}')"
    [ "$(decision)" = "deny" ]
}

@test "native: apply_patch always denies, even with a plan-like path" {
    hook codex apply_patch '{"command":"*** Begin Patch"}'
    [ "$(decision)" = "deny" ]
}

@test "native: the Grep and Glob tools deny from native with the tilth_search message" {
    hook claude Grep '{"pattern":"foo"}'
    [ "$(decision)" = "deny" ]
    [[ "$(reason)" == *tilth_search* ]]
    hook claude Glob '{"pattern":"**/*.js"}'
    [ "$(decision)" = "deny" ]
}

# ── Codex: tilth_write out-of-tree block ──────────────────────────────────

@test "codex tilth_write: a path outside the checkout denies and names it" {
    hook codex mcp__tilth__tilth_write "$(tilth_write_input /etc/x)"
    [ "$(decision)" = "deny" ]
    [[ "$(reason)" == */etc/x* ]]
    [[ "$(reason)" == *"Allowed roots"* ]]
    [[ "$(reason)" == *"$REPO"* ]]
}

@test "codex tilth_write: a path in the checkout allows" {
    hook codex mcp__tilth__tilth_write "$(tilth_write_input "$REPO/src/a.txt")"
    [ -z "$output" ]
}

@test "codex tilth_write: a symlink in the checkout that points outside denies" {
    ln -s /etc "$REPO/etc-link"
    hook codex mcp__tilth__tilth_write "$(tilth_write_input "$REPO/etc-link/x")"
    [ "$(decision)" = "deny" ]
    [[ "$(reason)" == *etc-link/x* ]]
}

@test "codex tilth_write: a relative path resolves against input cwd" {
    local j
    j=$(jq -nc --arg c "$REPO" '{cwd:$c, edits:[{path:"a.txt", ops:[]}]}')
    hook codex mcp__tilth__tilth_write "$j"
    [ -z "$output" ]
    j=$(jq -nc '{cwd:"/etc", edits:[{path:"a.txt", ops:[]}]}')
    hook codex mcp__tilth__tilth_write "$j"
    [ "$(decision)" = "deny" ]
}

@test "codex tilth_write: /tmp, .cheese, and the cheese data dir allow" {
    local p
    for p in /tmp/x /private/tmp/x "$REPO/../elsewhere/.cheese/spec.md" "$HOME/.local/share/cheese/r/x.md"; do
        hook codex mcp__tilth__tilth_write "$(tilth_write_input "$p")"
        [ -z "$output" ] || { echo "expected allow: $p" >&2; return 1; }
    done
}

@test "codex tilth_write: a move_file destination outside the checkout denies" {
    local j
    j=$(jq -nc --arg p "$REPO/a.txt" '{cwd:"/", edits:[{path:$p, ops:[{op:"move_file", dest:"/etc/b"}]}]}')
    hook codex mcp__tilth__tilth_write "$j"
    [ "$(decision)" = "deny" ]
    [[ "$(reason)" == */etc/b* ]]
}

@test "codex tilth_write: DOTFILES_WRITE_GUARD_ALLOW opens an extra root" {
    export DOTFILES_WRITE_GUARD_ALLOW="/etc/allowed,/usr/other"
    hook codex mcp__tilth__tilth_write "$(tilth_write_input /etc/allowed/x)"
    [ -z "$output" ]
    hook codex mcp__tilth__tilth_write "$(tilth_write_input /etc/not-allowed/x)"
    [ "$(decision)" = "deny" ]
}

@test "claude tilth_write is untouched (worktree-guard owns it)" {
    hook claude mcp__tilth__tilth_write "$(tilth_write_input /etc/x)"
    [ -z "$output" ]
}

# ── dispatcher: strip, null stdin, kill switch, timing ────────────────────

@test "strip-only cd hit emits updatedInput on claude and nothing on codex" {
    hook claude Bash "$(jq -nc --arg c "cd $REPO && ls" '{command:$c}')"
    [ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$output")" = "ls" ]
    hook codex Bash "$(jq -nc --arg c "cd $REPO && ls" '{command:$c}')"
    [ -z "$output" ]
}

@test "cd-git rewrite reason names the original and the wt-git command" {
    hook claude Bash '{"command":"cd /r && git status"}'
    [ "$(decision)" = "allow" ]
    [ "$(reason)" = "tool-reroute: cd /r && git status → wt-git /r status" ]
}

@test "null and non-object stdin exit 0 with no output" {
    local s
    for s in null 42 '"str"' '[]'; do
        run bash -c "printf '%s' '$s' | '$DEPLOY/hooks/tool-reroute.sh'"
        [ "$status" -eq 0 ]
        [ -z "$output" ] || { echo "output for $s" >&2; return 1; }
    done
}

@test "kill switch disables the hook" {
    local v json
    json=$(jq -nc '{tool_name:"Grep", tool_input:{pattern:"x"}, cwd:"/tmp"}')
    for v in 0 false off no OFF; do
        # shellcheck disable=SC2016  # $1/$2 expand inside the inner bash, by design
        run env DOTFILES_TOOL_REROUTE="$v" bash -c 'printf "%s" "$1" | "$2"' bash "$json" "$DEPLOY/hooks/tool-reroute.sh"
        [ "$status" -eq 0 ]
        [ -z "$output" ] || { echo "not disabled: $v" >&2; return 1; }
    done
    # shellcheck disable=SC2016  # $1/$2 expand inside the inner bash, by design
    run env DOTFILES_TOOL_REROUTE=1 bash -c 'printf "%s" "$1" | "$2"' bash "$json" "$DEPLOY/hooks/tool-reroute.sh"
    [ "$(decision)" = "deny" ]
}

@test "deny reasons carry the kill-switch hint when they fit" {
    hook claude Grep '{"pattern":"foo"}'
    [[ "$(reason)" == *"DOTFILES_TOOL_REROUTE=0"* ]]
}

@test "a 50K-char command finishes under 2 seconds and still denies" {
    local cmd start elapsed
    cmd="cat $(head -c 50000 /dev/zero | tr '\0' 'a')"
    start=$SECONDS
    hook claude Bash "$(jq -nc --arg c "$cmd" '{command:$c}')"
    elapsed=$((SECONDS - start))
    [ "$elapsed" -lt 2 ] || { echo "took ${elapsed}s" >&2; return 1; }
    [ "$(decision)" = "deny" ]
}

@test "long deny reasons keep the Run instead call under the raised cap" {
    local p="$REPO/$(head -c 600 /dev/zero | tr '\0' 'd')/f.txt"
    hook claude Read "$(jq -nc --arg p "$p" '{file_path:$p}')"
    [[ "$(reason)" == *tilth_read* ]]
    [[ "$(reason)" == *'Append #start-end'* ]]
}
