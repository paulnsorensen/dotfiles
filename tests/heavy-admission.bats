#!/usr/bin/env bats

load test_helper

HOOK="$REAL_DOTFILES_DIR/agents/hooks/heavy-admission.sh"

run_hook() {
    run bash -c 'printf "%s\n" "$1" | "$2"' _ "$1" "$HOOK"
}

@test "denies direct cargo test" {
    run_hook '{"tool_name":"Bash","tool_input":{"command":"cargo test"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}

@test "allows cargo test through heavy-run" {
    run_hook '{"tool_name":"Bash","tool_input":{"command":"heavy-run cargo test"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "allows ordinary cargo formatting" {
    run_hook '{"tool_name":"Bash","tool_input":{"command":"cargo fmt"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "denies canonical just ci" {
    run_hook '{"tool_name":"Bash","tool_input":{"command":"cd repo && just ci"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision":"deny"'* ]]
}
