#!/usr/bin/env bats
# Tests for the PermissionRequest/PermissionDenied observability hook.
#   agents/hooks/permission-log.sh — bash bridge (self-locating exec node)
#   agents/lib/permission-log.js   — appends one JSONL record per event
#
# WHY: a permission prompt or a deny is otherwise invisible after the fact.
# This hook never blocks or prints — it only appends to events.jsonl, fail-
# open on malformed input or a logging error, so observability can never
# affect enforcement.

load test_helper

HOOK_SH="$REAL_DOTFILES_DIR/agents/hooks/permission-log.sh"
LOGIC_JS="$REAL_DOTFILES_DIR/agents/lib/permission-log.js"
JSONL_JS="$REAL_DOTFILES_DIR/agents/lib/jsonl-log.js"

setup_file() {
    export GUARD_MASTER="$BATS_FILE_TMPDIR/guard-mocks"
    mkdir -p "$GUARD_MASTER/hooks" "$GUARD_MASTER/lib"
    cp "$HOOK_SH" "$GUARD_MASTER/hooks/permission-log.sh"
    cp "$LOGIC_JS" "$GUARD_MASTER/lib/permission-log.js"
    cp "$JSONL_JS" "$GUARD_MASTER/lib/jsonl-log.js"
    chmod +x "$GUARD_MASTER/hooks/permission-log.sh"
}

deploy_permlog() {
    local root="$1"
    mkdir -p "$root/hooks" "$root/lib"
    ln -s "$GUARD_MASTER/hooks/permission-log.sh" "$root/hooks/permission-log.sh"
    ln -s "$GUARD_MASTER/lib/permission-log.js" "$root/lib/permission-log.js"
    ln -s "$GUARD_MASTER/lib/jsonl-log.js" "$root/lib/jsonl-log.js"
}

setup() {
    setup_test_env
    DEPLOY="$TEST_HOME/.claude"
    deploy_permlog "$DEPLOY"
    W="$REAL_DOTFILES_DIR"
    export CLAUDE_PERMISSION_LOG_DIR="$BATS_TEST_TMPDIR/perm-log"
}

teardown() { teardown_test_env; }

log_file() { printf '%s' "$CLAUDE_PERMISSION_LOG_DIR/events.jsonl"; }

send() {
    local json="$1"
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/permission-log.sh'"
}

@test "permission-log: PermissionRequest event appends one record" {
    local json; json=$(jq -nc --arg w "$W" '{hook_event_name:"PermissionRequest", session_id:"s1", cwd:$w, permission_mode:"auto", tool_name:"Bash", tool_input:{command:"cd /x && ls"}, permission_suggestions:[{type:"addRules"}]}')
    send "$json"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
    local log; log=$(log_file)
    [ "$(wc -l <"$log")" -eq 1 ]
    [[ "$(jq -r .event <"$log")" == "PermissionRequest" ]]
    [[ "$(jq -r .tool_name <"$log")" == "Bash" ]]
    [[ "$(jq -r .command <"$log")" == "cd /x && ls" ]]
    [[ "$(jq -r '.suggestions[0].type' <"$log")" == "addRules" ]]
}

@test "permission-log: reason is sanitized and suggestions keep metadata only" {
    local json
    json=$(jq -nc --arg w "$W" '{hook_event_name:"PermissionDenied", cwd:$w, tool_name:"Bash", reason:"TOKEN=reason-secret", permission_suggestions:[{type:"addRules", rule:"TOKEN=rule-secret"}]}')
    send "$json"
    [ "$status" -eq 0 ]
    local log; log=$(log_file)
    [[ "$(jq -r .reason <"$log")" == "TOKEN=<redacted>" ]]
    [[ "$(jq -c '.suggestions' <"$log")" == '[{"type":"addRules"}]' ]]
}

@test "permission-log: PermissionDenied event appends a second record" {
    local req; req=$(jq -nc --arg w "$W" '{hook_event_name:"PermissionRequest", session_id:"s1", cwd:$w, permission_mode:"auto", tool_name:"Bash", tool_input:{command:"cd /x && ls"}, permission_suggestions:[{type:"addRules"}]}')
    send "$req"
    [ "$status" -eq 0 ]
    local den; den=$(jq -nc --arg w "$W" '{hook_event_name:"PermissionDenied", session_id:"s1", cwd:$w, tool_name:"Bash", tool_input:{command:"rm -rf /tmp/x"}, reason:"Blocked by classifier"}')
    send "$den"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
    local log; log=$(log_file)
    [ "$(wc -l <"$log")" -eq 2 ]
    [[ "$(sed -n '2p' "$log" | jq -r .event)" == "PermissionDenied" ]]
    [[ "$(sed -n '2p' "$log" | jq -r .reason)" == "Blocked by classifier" ]]
    [[ "$(sed -n '2p' "$log" | jq -r .command)" == "rm -rf /tmp/x" ]]
}

@test "permission-log: malformed stdin fails open (allow, exit 0, no file)" {
    run bash -c "printf 'not json' | '$DEPLOY/hooks/permission-log.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
    [ ! -e "$(log_file)" ]
}

@test "permission-log: an unrelated event (PreToolUse) is not logged" {
    local json; json=$(jq -nc --arg w "$W" '{hook_event_name:"PreToolUse", cwd:$w, tool_name:"Bash", tool_input:{command:"ls"}}')
    send "$json"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
    [ ! -e "$(log_file)" ]
}
