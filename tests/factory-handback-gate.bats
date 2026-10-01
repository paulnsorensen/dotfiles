#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for claude/hooks/factory-handback-gate.js through hook-runner.js.
# Coverage: StructuredOutput contract denials, agent scoping, the
# SubagentStop backstop, and (when the Wheypoint archive is installed) the
# real revision write, stale-parent refusal, and gated derivation.
# Every mid-test [[ ]] ends in `|| false`: bash 3.2 (macOS /bin/bash) does
# not fail a test on a mid-test [[ ]] under errexit.

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

# Pipe one hook event through the runner, the same path Claude Code uses.
run_gate() {
    run bash -c 'printf "%s" "$1" | node "$2/hook-runner.js" factory-handback-gate.js' _ "$1" "$HOOKS_DIR"
}

pre_event() {
    local agent="$1" input="$2" cwd="${3:-$TEST_HOME}"
    printf '{"hook_event_name":"PreToolUse","tool_name":"StructuredOutput","agent_type":"%s","agent_id":"a1","cwd":"%s","tool_input":%s}' "$agent" "$cwd" "$input"
}

setup() {
    setup_test_env
    export FACTORY_GATE_SPOOL="$TEST_HOME/spool"
    export FACTORY_GATE_WHEYPOINT="$ORIGINAL_HOME/.claude/skills/wheypoint/scripts/wheypoint.pyz"
}

teardown() {
    teardown_test_env
}

@test "gate: denies a coder status outside the handback vocabulary" {
    run_gate "$(pre_event factory-coder '{"status":"done","next":"age","wheypoint_ref":"wheypoint:acme-demo/run--alpha","orientation":"Implemented."}')"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    [[ "$output" == *'status: expected ok'* ]] || false
}

@test "gate: denies a malformed wheypoint ref" {
    run_gate "$(pre_event factory-coder '{"status":"ok","next":"age","wheypoint_ref":".cheese/notes/alpha.md","orientation":"Implemented."}')"
    [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    [[ "$output" == *'wheypoint_ref: expected wheypoint:'* ]] || false
}

@test "gate: denies a next move the agent does not own" {
    run_gate "$(pre_event factory-coder '{"status":"ok","next":"cure","wheypoint_ref":"wheypoint:acme-demo/run--alpha","orientation":"Implemented."}')"
    [[ "$output" == *'next: factory-coder may hand off only to age, hold'* ]] || false
}

@test "gate: denies a boss fork with fewer than two options" {
    run_gate "$(pre_event curd-boss '{"action":"raise_fork","wheypoint_ref":"wheypoint:acme-demo/run--alpha","fork":{"question":"Which base?","options":[{"option":"main"}]}}')"
    [[ "$output" == *'fork.options: a fork needs at least two options'* ]] || false
}

@test "gate: denies a boss fork option that does not say what it breaks" {
    run_gate "$(pre_event curd-boss '{"action":"raise_fork","wheypoint_ref":"wheypoint:acme-demo/run--alpha","fork":{"question":"Which base?","options":[{"option":"main","breaks":"imports"},{"option":"curd/alpha"}]}}')"
    [[ "$output" == *'fork.options[1]: each option needs a one-line option and breaks'* ]] || false
}

@test "gate: ignores StructuredOutput from a non-factory agent" {
    run_gate "$(pre_event coder '{"status":"bogus"}')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "backstop: blocks a factory agent that stops without a handback" {
    run_gate '{"hook_event_name":"SubagentStop","agent_type":"factory-coder","agent_id":"a9","stop_hook_active":false}'
    [[ "$output" == *'"decision":"block"'* ]] || false
    [[ "$output" == *'call StructuredOutput with your handback'* ]] || false
}

@test "backstop: lets a second stop through to avoid a block loop" {
    run_gate '{"hook_event_name":"SubagentStop","agent_type":"factory-coder","agent_id":"a9","stop_hook_active":true}'
    [[ "$output" != *'"decision":"block"'* ]] || false
}

# ---- real Wheypoint round trip (skips where the archive is not installed) ----

seed_curd_record() {
    [ -f "$FACTORY_GATE_WHEYPOINT" ] || skip "wheypoint archive not installed"
    export XDG_DATA_HOME="$TEST_HOME/xdg"
    REPO="$TEST_HOME/repo"
    git init -q "$REPO"
    git -C "$REPO" remote add origin https://example.com/acme/demo.git
    mkdir -p "$REPO/specs"
    : > "$REPO/specs/demo.md"
    (cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" checkpoint --work-id run --orientation "Run." \
        --decision "Run started." --rationale "test" --next hold --context specs/demo.md --no-note >/dev/null)
    (cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" fork run run--alpha --orientation "Curd alpha." >/dev/null)
    PROJECT=$(cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" show run--alpha | jq -r '.record.project_key')
    REV=$(cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" show run--alpha | jq -r '.revision_id')
}

# Build a coder handback pinned to the seeded revision.
coder_handback() {
    jq -nc --arg ref "wheypoint:$PROJECT/run--alpha@$REV" --arg o "$1" \
        '{status: "ok", next: "age", wheypoint_ref: $ref, orientation: $o}'
}

@test "gate: commits a valid handback and returns the new pinned ref" {
    seed_curd_record
    local event new_ref
    event=$(pre_event factory-coder "$(coder_handback Implemented.)" "$REPO")
    run_gate "$event"
    [[ "$output" == *'"permissionDecision":"allow"'* ]] || false
    new_ref=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.wheypoint_ref')
    [[ "$new_ref" == "wheypoint:$PROJECT/run--alpha@rev-"* ]] || false
    [[ "$new_ref" != *"@$REV" ]] || false
    [ -f "$FACTORY_GATE_SPOOL/factory-handback/a1.done" ]
}

@test "gate: denies a handback pinned to a superseded revision" {
    seed_curd_record
    local first second
    first=$(pre_event factory-coder "$(coder_handback First.)" "$REPO")
    second=$(pre_event factory-coder "$(coder_handback Second.)" "$REPO")
    run_gate "$first"
    [[ "$output" == *'"permissionDecision":"allow"'* ]] || false
    run_gate "$second"
    [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    [[ "$output" == *'stale-parent'* ]] || false
}

@test "gate: a boss fork parks the curd as gated" {
    seed_curd_record
    local input event
    input=$(jq -nc --arg ref "wheypoint:$PROJECT/run--alpha@$REV" \
        '{action: "raise_fork", wheypoint_ref: $ref, fork: {question: "Which base branch?", options: [{option: "origin/main", breaks: "beta cannot import alpha"}, {option: "curd/alpha", breaks: "stack bookkeeping"}]}}')
    event=$(pre_event curd-boss "$input" "$REPO")
    run_gate "$event"
    [[ "$output" == *'"record_status":"gated"'* ]] || false
    run bash -c 'cd "$1" && python3 "$2" list --gated --forked-from run | jq -r ".items[].work_id"' _ "$REPO" "$FACTORY_GATE_WHEYPOINT"
    [ "$output" = "run--alpha" ]
}
