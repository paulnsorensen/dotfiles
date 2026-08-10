#!/usr/bin/env bats

load test_helper

HOOK_SH="$REAL_DOTFILES_DIR/agents/hooks/doom-loop-guard.sh"
HOOK_JS="$REAL_DOTFILES_DIR/agents/lib/doom-loop-guard.js"

setup() {
    setup_test_env
    export DOOM_LOOP_STATE_DIR="$TEST_HOME/doom-loop"
    DEPLOY="$TEST_HOME/.claude"
    mkdir -p "$DEPLOY/hooks" "$DEPLOY/lib"
    cp "$HOOK_SH" "$DEPLOY/hooks/doom-loop-guard.sh"
    cp "$HOOK_JS" "$DEPLOY/lib/doom-loop-guard.js"
    chmod +x "$DEPLOY/hooks/doom-loop-guard.sh"
}

teardown() {
    teardown_test_env
}

event() {
    local session="$1" tool="$2" input="$3" harness="${4:-claude}" scope="${5:-prompt-1}" invocation="${6:-}"
    jq -nc \
        --arg session "$session" \
        --arg tool "$tool" \
        --argjson input "$input" \
        --arg harness "$harness" \
        --arg scope "$scope" \
        --arg invocation "$invocation" \
        '{session_id:$session, tool_name:$tool, tool_input:$input, harness:$harness}
         + (if $harness == "codex" then {turn_id:$scope} else {prompt_id:$scope} end)
         + (if $invocation == "" then {} else {tool_use_id:$invocation} end)'
}

fire() {
    local payload="$1"
    printf '%s' "$payload" | "$DEPLOY/hooks/doom-loop-guard.sh"
}

action() {
    local output
    output="$(fire "$1")"
    if [[ -z "$output" ]]; then
        printf 'allow'
    elif jq -e '.continue == false' >/dev/null <<<"$output"; then
        printf 'stop'
    elif [[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$output")" == "deny" ]]; then
        printf 'block'
    else
        printf 'observe'
    fi
}

@test "recommended ladder observes at 2, blocks at 3, and stops Claude at 6" {
    local payload
    payload="$(event s1 Bash '{"command":"npm test"}')"

    [[ "$(action "$payload")" == "allow" ]]
    [[ "$(action "$payload")" == "observe" ]]
    [[ "$(action "$payload")" == "block" ]]
    [[ "$(action "$payload")" == "block" ]]
    [[ "$(action "$payload")" == "block" ]]
    [[ "$(action "$payload")" == "stop" ]]
}

@test "Codex stop-strength verdict remains a deny with stop guidance" {
    local payload output
    payload="$(event s2 Bash '{"command":"npm test"}' codex)"
    for _ in 1 2 3 4 5; do fire "$payload" >/dev/null; done
    output="$(fire "$payload")"

    [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" == "deny" ]]
    [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" == *"stop threshold"* ]]
}

@test "canonical object keys identify the same call" {
    [[ "$(action "$(event s3 mcp__x__read '{"path":"a","limit":2}')")" == "allow" ]]
    [[ "$(action "$(event s3 mcp__x__read '{"limit":2,"path":"a"}')")" == "observe" ]]
}

@test "changing input resets only that tool while other tools do not" {
    [[ "$(action "$(event s4 Read '{"path":"a"}')")" == "allow" ]]
    [[ "$(action "$(event s4 Bash '{"command":"pwd"}')")" == "allow" ]]
    [[ "$(action "$(event s4 Read '{"path":"a"}')")" == "observe" ]]
    [[ "$(action "$(event s4 Read '{"path":"b"}')")" == "allow" ]]
    [[ "$(action "$(event s4 Read '{"path":"b"}')")" == "observe" ]]
}

@test "replayed hook delivery counts once by tool-use id" {
    [[ "$(action "$(event s5 Bash '{"command":"pwd"}' codex t1 call-1)")" == "allow" ]]
    [[ "$(action "$(event s5 Bash '{"command":"pwd"}' codex t1 call-1)")" == "allow" ]]
    [[ "$(action "$(event s5 Bash '{"command":"pwd"}' codex t1 call-2)")" == "observe" ]]
}

@test "a new user prompt resets repetition counts" {
    [[ "$(action "$(event s9 Bash '{"command":"pwd"}' claude p1)")" == "allow" ]]
    [[ "$(action "$(event s9 Bash '{"command":"pwd"}' claude p1)")" == "observe" ]]
    [[ "$(action "$(event s9 Bash '{"command":"pwd"}' claude p2)")" == "allow" ]]
    [[ "$(action "$(event s10 Bash '{"command":"pwd"}' codex t1)")" == "allow" ]]
    [[ "$(action "$(event s10 Bash '{"command":"pwd"}' codex t2)")" == "allow" ]]
}

@test "sessions are isolated" {
    [[ "$(action "$(event s6 Read '{"path":"a"}')")" == "allow" ]]
    [[ "$(action "$(event s7 Read '{"path":"a"}')")" == "allow" ]]
}

@test "delegation and polling tools are exempt" {
    local tool payload
    for tool in Task Agent task spawn_agent write_stdin wait wait_agent functions.wait; do
        payload="$(event "exempt-$tool" "$tool" '{}')"
        [[ "$(action "$payload")" == "allow" ]]
        [[ "$(action "$payload")" == "allow" ]]
        [[ "$(action "$payload")" == "allow" ]]
    done
}

@test "malformed input, missing identity, and unwritable state fail open" {
    [[ -z "$(printf '{' | "$DEPLOY/hooks/doom-loop-guard.sh")" ]]
    [[ -z "$(fire '{"tool_name":"Read","tool_input":{"path":"a"}}')" ]]

    export DOOM_LOOP_STATE_DIR="$TEST_HOME/not-a-directory"
    printf 'x' > "$DOOM_LOOP_STATE_DIR"
    [[ "$(action "$(event s8 Read '{"path":"a"}')")" == "allow" ]]
}
