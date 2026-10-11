#!/usr/bin/env bats
# Tests for the wheypoint-stop-gate Stop hook (Claude-only).
#   agents/hooks/wheypoint-stop-gate.sh — self-contained bash + jq gate
#
# WHY: a Haiku prompt hook fired on every stop, including Q&A turns that changed
# nothing, and forced a wheypoint. The gate blocks only when the transcript shows
# a file change after the last wheypoint, and (with no wheypoint yet) only when
# the working tree is dirty. Everything else is fail-open silence.

load test_helper

HOOK="$REAL_DOTFILES_DIR/agents/hooks/wheypoint-stop-gate.sh"

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v git >/dev/null 2>&1 || skip "git not installed"
    REPO="$TEST_HOME/repo"
    TRANSCRIPT="$TEST_HOME/transcript.jsonl"
    : >"$TRANSCRIPT"
    mkdir -p "$REPO"
    (
        cd "$REPO" || return 1
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo code >code.txt
        git add code.txt
        git commit -m "init" --quiet
    )
}
teardown() { teardown_test_env; }

# ── Transcript builders (append one assistant entry per call) ───────────────

# $1=tool name, $2=input JSON
tool_use() {
    jq -cn --arg n "$1" --argjson i "$2" \
        '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",name:$n,input:$i}]}}' \
        >>"$TRANSCRIPT"
}

# $1=text
say() {
    jq -cn --arg t "$1" \
        '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' \
        >>"$TRANSCRIPT"
}

user_says() {
    jq -cn --arg t "$1" \
        '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' \
        >>"$TRANSCRIPT"
}

# The sandbox lives under /tmp, which the gate ignores, so edits name a path
# outside /tmp. The gate never opens the edited file.
edit_repo_file() { tool_use Edit '{"file_path":"/work/repo/code.txt"}'; }
dirty_tree() { echo change >>"$REPO/code.txt"; }

# $1=stop_hook_active (default false)
stop_payload() {
    jq -cn --arg t "$TRANSCRIPT" --arg c "$REPO" --argjson a "${1:-false}" \
        '{transcript_path:$t,cwd:$c,stop_hook_active:$a}'
}

run_gate() { run bash "$HOOK" <<<"$(stop_payload "$@")"; }

assert_silent() {
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Silent: nothing in progress ─────────────────────────────────────────────

@test "silent on a Q&A session with no file change" {
    user_says "how long before it fires?"
    tool_use Bash '{"command":"ls"}'
    say "It fires at once."
    run_gate
    assert_silent
}

@test "silent when the file change is committed and no wheypoint exists" {
    edit_repo_file
    (cd "$REPO" && echo change >>code.txt && git commit -aqm work)
    run_gate
    assert_silent
}

@test "silent when the wheypoint came after the last file change" {
    edit_repo_file
    dirty_tree
    say "Wheypoint dropped: [note](/tmp/note.md)"
    run_gate
    assert_silent
}

@test "silent when a /wheypoint skill call came after the last file change" {
    edit_repo_file
    dirty_tree
    tool_use Skill '{"skill":"wheypoint"}'
    run_gate
    assert_silent
}

@test "silent for writes under /tmp and .cheese" {
    dirty_tree
    tool_use Write '{"file_path":"/tmp/intent.json"}'
    tool_use Edit '{"file_path":"/work/repo/.cheese/notes/x.md"}'
    tool_use mcp__tilth__tilth_write '{"edits":[{"path":"/tmp/a.json","ops":[]}]}'
    run_gate
    assert_silent
}

@test "silent when a user message quotes the wheypoint marker" {
    user_says "Wheypoint dropped: [note](/tmp/note.md)"
    run_gate
    assert_silent
}

# ── Blocks: work in progress ────────────────────────────────────────────────

@test "blocks with a write request when files changed and the tree is dirty" {
    edit_repo_file
    dirty_tree
    run_gate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == "Work is uncommitted. Write a wheypoint"* ]]
}

@test "blocks with an update request when a file changed after the wheypoint" {
    say "Wheypoint dropped: [note](/tmp/note.md)"
    edit_repo_file
    run_gate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == "Update this session's wheypoint"* ]]
}

@test "a dirty tree without a file change in the transcript does not block" {
    dirty_tree
    say "Nothing edited this session."
    run_gate
    assert_silent
}

@test "blocks on a tilth_write to a repo path" {
    say "Wheypoint dropped: [note](/tmp/note.md)"
    tool_use mcp__tilth__tilth_write '{"edits":[{"path":"/work/repo/code.txt","ops":[]}]}'
    run_gate
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "blocks on a git commit after the wheypoint" {
    say "Wheypoint dropped: [note](/tmp/note.md)"
    tool_use Bash '{"command":"cd x && git commit -m msg"}'
    run_gate
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "does not treat git status or git log as a change" {
    say "Wheypoint dropped: [note](/tmp/note.md)"
    tool_use Bash '{"command":"git status && git log --oneline"}'
    run_gate
    assert_silent
}

# ── Guards and fail-open ────────────────────────────────────────────────────

@test "silent when stop_hook_active is true" {
    edit_repo_file
    dirty_tree
    run_gate true
    assert_silent
}

@test "silent when WHEYPOINT_STOP_GATE=0" {
    edit_repo_file
    dirty_tree
    run env WHEYPOINT_STOP_GATE=0 bash "$HOOK" <<<"$(stop_payload)"
    assert_silent
}

@test "silent when the transcript is missing" {
    rm "$TRANSCRIPT"
    run_gate
    assert_silent
}

@test "silent on empty or invalid stdin" {
    run bash "$HOOK" <<<""
    assert_silent
    run bash "$HOOK" <<<"not json"
    assert_silent
}

@test "skips malformed transcript lines" {
    echo "{broken" >>"$TRANSCRIPT"
    edit_repo_file
    dirty_tree
    run_gate
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}
