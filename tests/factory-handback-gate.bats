#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for claude/hooks/factory-handback-gate.js through hook-runner.js.
# Coverage: handback scoping, contract denials, the settings registration,
# and (when the Wheypoint archive is installed) the real revision write,
# stale-parent refusal, gated derivation, and fork resolution.
# Every mid-test [[ ]] ends in `|| false`: bash 3.2 (macOS /bin/bash) does
# not fail a test on a mid-test [[ ]] under errexit.

load test_helper

HOOKS_DIR="$REAL_DOTFILES_DIR/claude/hooks"

# Pipe one hook event through the runner, the same path Claude Code uses.
run_gate() {
    run bash -c 'printf "%s" "$1" | node "$2/hook-runner.js" factory-handback-gate.js' _ "$1" "$HOOKS_DIR"
}

pre_event() {
    local input="$1" cwd="${2:-$TEST_HOME}"
    printf '{"hook_event_name":"PreToolUse","tool_name":"StructuredOutput","agent_type":"coder","agent_id":"a1","cwd":"%s","tool_input":%s}' "$cwd" "$input"
}

setup() {
    setup_test_env
    export FACTORY_GATE_WHEYPOINT="$ORIGINAL_HOME/.claude/skills/wheypoint/scripts/wheypoint.pyz"
}

teardown() {
    teardown_test_env
}

@test "settings: the gate is registered once on StructuredOutput" {
    run yq -r '.claude.hooks.PreToolUse[] | select(.hooks[].command | test("factory-handback-gate")) | .matcher' \
        "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "StructuredOutput" ]
}

@test "scope: ignores StructuredOutput without a factory role" {
    run_gate "$(pre_event '{"status":"bogus","wheypoint_ref":"wheypoint:acme-demo/factory-run--alpha"}')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "scope: ignores a role-shaped handback whose ref is not a factory record" {
    run_gate "$(pre_event '{"role":"coder","status":"bogus","wheypoint_ref":"wheypoint:acme-demo/auth-retry"}')"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "gate: denies a coder status outside the handback vocabulary" {
    run_gate "$(pre_event '{"role":"coder","status":"done","next":"age","wheypoint_ref":"wheypoint:acme-demo/factory-run--alpha","orientation":"Implemented."}')"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    [[ "$output" == *'status: expected ok'* ]] || false
}

@test "gate: denies a malformed factory ref" {
    run_gate "$(pre_event '{"role":"coder","status":"ok","next":"age","wheypoint_ref":"wheypoint:acme-demo/factory-run--alpha@rev-xyz","orientation":"Implemented."}')"
    [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    [[ "$output" == *'wheypoint_ref: expected wheypoint:'* ]] || false
}

@test "gate: denies a next move the role does not own" {
    run_gate "$(pre_event '{"role":"coder","status":"ok","next":"cure","wheypoint_ref":"wheypoint:acme-demo/factory-run--alpha","orientation":"Implemented."}')"
    [[ "$output" == *'next: a coder may hand off only to age, hold'* ]] || false
}

@test "gate: denies a boss fork with fewer than two options" {
    run_gate "$(pre_event '{"role":"boss","action":"raise_fork","wheypoint_ref":"wheypoint:acme-demo/factory-run--alpha","fork":{"question":"Which base?","options":[{"option":"main"}]}}')"
    [[ "$output" == *'fork.options: a fork needs at least two options'* ]] || false
}

@test "gate: denies a boss fork option that does not say what it breaks" {
    run_gate "$(pre_event '{"role":"boss","action":"raise_fork","wheypoint_ref":"wheypoint:acme-demo/factory-run--alpha","fork":{"question":"Which base?","options":[{"option":"main","breaks":"imports"},{"option":"curd/alpha"}]}}')"
    [[ "$output" == *'fork.options[1]: each option needs a one-line option and breaks'* ]] || false
}

@test "gate: denies a boss resolve without the user's quote" {
    run_gate "$(pre_event '{"role":"boss","action":"dispatch_coder","brief":"Do it.","wheypoint_ref":"wheypoint:acme-demo/factory-run--alpha","resolves":[{"entry_id":"q-0123456789ab"}]}')"
    [[ "$output" == *"resolves[0]: each resolve needs an entry_id from show and the user's quote"* ]] || false
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
    (cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" checkpoint --work-id factory-run --orientation "Run." \
        --decision "Run started." --rationale "test" --next hold --context specs/demo.md --no-note >/dev/null)
    (cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" fork factory-run factory-run--alpha --orientation "Curd alpha." >/dev/null)
    PROJECT=$(cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" show factory-run--alpha | jq -r '.record.project_key')
    REV=$(cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" show factory-run--alpha | jq -r '.revision_id')
}

current_rev() {
    (cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" show factory-run--alpha | jq -r '.revision_id')
}

# Build a coder handback pinned to one revision.
coder_handback() {
    jq -nc --arg ref "wheypoint:$PROJECT/factory-run--alpha@$2" --arg o "$1" \
        '{role: "coder", status: "ok", next: "age", wheypoint_ref: $ref, orientation: $o}'
}

@test "gate: commits a valid handback and returns the new pinned ref" {
    seed_curd_record
    local new_ref
    run_gate "$(pre_event "$(coder_handback Implemented. "$REV")" "$REPO")"
    [[ "$output" == *'"permissionDecision":"allow"'* ]] || false
    new_ref=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.wheypoint_ref')
    [ "$new_ref" = "wheypoint:$PROJECT/factory-run--alpha@$(current_rev)" ]
    [[ "$new_ref" != *"@$REV" ]] || false
}

@test "gate: denies a handback pinned to a superseded revision" {
    seed_curd_record
    run_gate "$(pre_event "$(coder_handback First. "$REV")" "$REPO")"
    [[ "$output" == *'"permissionDecision":"allow"'* ]] || false
    run_gate "$(pre_event "$(coder_handback Second. "$REV")" "$REPO")"
    [[ "$output" == *'"permissionDecision":"deny"'* ]] || false
    [[ "$output" == *'stale-parent'* ]] || false
}

@test "gate: a boss fork parks the curd as gated, and a boss resolve clears it" {
    seed_curd_record
    local fork entry resolve
    fork=$(jq -nc --arg ref "wheypoint:$PROJECT/factory-run--alpha@$REV" \
        '{role: "boss", action: "raise_fork", wheypoint_ref: $ref, fork: {question: "Which base branch?", options: [{option: "origin/main", breaks: "beta cannot import alpha"}, {option: "curd/alpha", breaks: "stack bookkeeping"}]}}')
    run_gate "$(pre_event "$fork" "$REPO")"
    [[ "$output" == *'"record_status":"gated"'* ]] || false
    run bash -c 'cd "$1" && python3 "$2" list --gated --forked-from factory-run | jq -r ".items[].work_id"' _ "$REPO" "$FACTORY_GATE_WHEYPOINT"
    [ "$output" = "factory-run--alpha" ]

    entry=$(cd "$REPO" && python3 "$FACTORY_GATE_WHEYPOINT" show factory-run--alpha \
        | jq -r '.record.questions[0].entry_id')
    resolve=$(jq -nc --arg ref "wheypoint:$PROJECT/factory-run--alpha@$(current_rev)" --arg id "$entry" \
        '{role: "boss", action: "dispatch_coder", brief: "Stack on curd/alpha.", wheypoint_ref: $ref, resolves: [{entry_id: $id, decision: "Stack on curd/alpha.", quote: "use the stack"}]}')
    run_gate "$(pre_event "$resolve" "$REPO")"
    [[ "$output" == *'"permissionDecision":"allow"'* ]] || false
    [[ "$output" != *'"record_status":"gated"'* ]] || false
}
