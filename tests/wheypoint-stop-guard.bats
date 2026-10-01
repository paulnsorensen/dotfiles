#!/usr/bin/env bats
# Tests for the wheypoint-stop-guard Stop hook (Claude-only).
#   agents/hooks/wheypoint-stop-guard.sh - bash wrapper + streaming jq reducer
#
# WHY: a session that already ran a wheypoint checkpoint must not end with a
# stale record. The hook reads the session transcript (records store no session
# id) and blocks the stop when a genuine user prompt or any non-wheypoint tool
# call follows the LAST successful checkpoint. It stays silent for sessions
# with no successful checkpoint, never blocks twice in a row, and fails open.

load test_helper

HOOK="$REAL_DOTFILES_DIR/agents/hooks/wheypoint-stop-guard.sh"
CP_CMD='python3 /x/wheypoint/scripts/wheypoint.pyz checkpoint intent.json'
CP_OK='{"ok": true, "command": "checkpoint", "work_id": "wk-123", "record": {"work_id": "other"}}'

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    TR="$TEST_HOME/transcript.jsonl"
    : >"$TR"
    N=0
}
teardown() { teardown_test_env; }

# Fixture builders: each appends one Claude JSONL entry to $TR.
prompt() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:$t}}' >>"$TR"; }
tool() { # $1=name $2=input-json $3=tool_use id
    jq -cn --arg n "$1" --argjson i "$2" --arg id "$3" \
        '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:$id,name:$n,input:$i}]}}' >>"$TR"
}
result() { # $1=id $2=output text $3=is_error (true|false)
    jq -cn --arg id "$1" --arg o "$2" --argjson e "${3:-false}" \
        '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:$id,content:$o,is_error:$e}]}}' >>"$TR"
}
bash_call() { # $1=command $2=output $3=is_error
    N=$((N + 1))
    tool Bash "$(jq -cn --arg c "$1" '{command:$c}')" "t$N"
    result "t$N" "$2" "${3:-false}"
}
checkpoint() { bash_call "$CP_CMD" "$CP_OK"; }

run_hook() { # $1=extra payload json (optional)
    local extra="${1:-}" payload
    [[ -n "$extra" ]] || extra='{}'
    payload="$(jq -cn --arg p "$TR" --argjson x "$extra" '{transcript_path:$p,hook_event_name:"Stop"} + $x')"
    run bash "$HOOK" <<<"$payload"
}

assert_allow() { [ "$status" -eq 0 ]; [ -z "$output" ]; }

@test "allows a session with no checkpoint" {
    prompt "hello"
    bash_call "ls" "a"
    run_hook
    assert_allow
}

@test "allows when the checkpoint is the last action" {
    prompt "hello"
    bash_call "ls" "a"
    checkpoint
    run_hook
    assert_allow
}

@test "blocks when a Read follows the checkpoint" {
    prompt "hello"
    checkpoint
    N=$((N + 1))
    tool Read '{"file_path":"/a"}' "t$N"
    result "t$N" "content"
    run_hook
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == *"/wheypoint"* ]]
}

@test "blocks when a new user prompt follows the checkpoint" {
    checkpoint
    prompt "now do something else"
    run_hook
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "blocks on a user prompt delivered as a text block" {
    checkpoint
    jq -cn '{type:"user",message:{role:"user",content:[{type:"text",text:"more please"}]}}' >>"$TR"
    run_hook
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "allows when only system-injected messages follow the checkpoint" {
    checkpoint
    prompt "<system-reminder>note</system-reminder>"
    prompt "<command-name>/wheypoint</command-name>"
    jq -cn '{type:"user",isMeta:true,message:{role:"user",content:"skill body"}}' >>"$TR"
    run_hook
    assert_allow
}

@test "allows when only a failed checkpoint exists (is_error)" {
    prompt "hello"
    bash_call "$CP_CMD" "boom" true
    bash_call "ls" "a"
    run_hook
    assert_allow
}

@test "allows when the checkpoint output reports ok false" {
    bash_call "$CP_CMD" '{"ok": false, "error": "refused"}'
    bash_call "ls" "a"
    run_hook
    assert_allow
}

@test "allows when only wheypoint commands and the Skill follow the checkpoint" {
    checkpoint
    bash_call "python3 /x/wheypoint.pyz turns" "{}"
    bash_call "python3 '/x/wheypoint.pyz' show --ref wk-123" "{}"
    bash_call "python3 /x/wheypoint.pyz validate intent.json" "{}"
    N=$((N + 1))
    tool Skill '{"skill":"wheypoint"}' "t$N"
    result "t$N" "ok"
    run_hook
    assert_allow
}

@test "a later successful checkpoint clears earlier staleness" {
    checkpoint
    bash_call "ls" "a"
    prompt "more"
    checkpoint
    run_hook
    assert_allow
}

@test "detects a checkpoint with quotes and flags before the subcommand" {
    bash_call "python3 \"/x/wheypoint.pyz\" --json checkpoint -" "$CP_OK"
    bash_call "ls" "a"
    run_hook
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "allows when stop_hook_active is true" {
    checkpoint
    prompt "more"
    run_hook '{"stop_hook_active":true}'
    assert_allow
}

@test "allows when the transcript is missing" {
    rm -f "$TR"
    run_hook
    assert_allow
}

@test "allows when the payload has no transcript_path or is not JSON" {
    run bash "$HOOK" <<<'{"hook_event_name":"Stop"}'
    assert_allow
    run bash "$HOOK" <<<'not json'
    assert_allow
}

@test "skips unparseable transcript lines" {
    checkpoint
    printf 'garbage{\n' >>"$TR"
    prompt "more"
    run_hook
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "off switch allows a stale session" {
    checkpoint
    prompt "more"
    WHEYPOINT_STOP_GUARD=0 run_hook
    assert_allow
    WHEYPOINT_STOP_GUARD=off run_hook
    assert_allow
}

@test "block reason names the work item parsed from the checkpoint output" {
    checkpoint
    prompt "more"
    run_hook
    [[ "$(jq -r '.reason' <<<"$output")" == *"wk-123"* ]]
}

@test "block reason omits the work item when the output has no work_id" {
    bash_call "$CP_CMD" '{"ok": true}'
    prompt "more"
    run_hook
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" != *"Work item"* ]]
}

@test "registry registers the hook for claude on Stop" {
    run yq -o=json '.hooks["wheypoint-stop-guard"]' "$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.event' <<<"$output")" = "Stop" ]
    [ "$(jq -c '.harnesses' <<<"$output")" = '["claude"]' ]
    [ "$(jq -r '.script' <<<"$output")" = "agents/hooks/wheypoint-stop-guard.sh" ]
}
