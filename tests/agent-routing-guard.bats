#!/usr/bin/env bats
# PreToolUse dispatch routing guard coverage for Claude and Codex.

load test_helper

HOOK="$REAL_DOTFILES_DIR/agents/hooks/agent-routing-guard.sh"

setup() {
    setup_test_env
    mkdir -p "$HOME/.claude/agents" "$HOME/.codex/agents"
    cat >"$HOME/.claude/agents/coder.md" <<'EOF'
---
model: sonnet
effort: medium
---
coder
EOF
    cat >"$HOME/.claude/agents/reviewer.md" <<'EOF'
---
model: opus
effort: high
---
reviewer
EOF
    cat >"$HOME/.codex/agents/coder.toml" <<'EOF'
model = "gpt-5.6-sol"
model_reasoning_effort = "medium"
EOF
}

teardown() { teardown_test_env; }

assert_denied() {
    [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = deny ]
}

claude_event() {
    local role="$1" model="${2-}" effort="${3-}"
    jq -nc --arg role "$role" --arg model "$model" --arg effort "$effort" '
      {tool_name:"Agent", tool_input:({subagent_type:$role} +
        (if $model != "" then {model:$model} else {} end) +
        (if $effort != "" then {effort:$effort} else {} end))}
    '
}

codex_event() {
    local role="$1" model="${2-}" effort="${3-}" fork="${4-}"
    jq -nc --arg role "$role" --arg model "$model" --arg effort "$effort" --arg fork "$fork" '
      {tool_name:"spawn_agent", tool_input:({agent_type:$role} +
        (if $model != "" then {model:$model} else {} end) +
        (if $effort != "" then {reasoning_effort:$effort} else {} end) +
        (if $fork != "" then {fork_turns:$fork} else {} end))}
    '
}

@test "unrelated tools emit no routing decision" {
    run "$HOOK" <<< '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Claude generic role is denied with named-role guidance" {
    run "$HOOK" <<< "$(claude_event general-purpose)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"named"* ]]
    [[ "$output" == *"coder"* ]]
}

@test "Claude coder uses rendered model and effort" {
    run "$HOOK" <<< "$(claude_event coder sonnet medium)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Claude model mismatch is denied unless the operator override matches" {
    run "$HOOK" <<< "$(claude_event coder opus medium)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"model"* ]]
    run env DOTFILES_AGENT_MODEL_OVERRIDE=opus "$HOOK" <<< "$(claude_event coder opus medium)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Fable and Terra are denied even with an override" {
    run env DOTFILES_AGENT_MODEL_OVERRIDE=fable "$HOOK" <<< "$(claude_event coder fable medium)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"unsupported"* ]]
    run env DOTFILES_AGENT_MODEL_OVERRIDE=gpt-5.6-terra "$HOOK" <<< "$(codex_event coder gpt-5.6-terra medium none)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"unsupported"* ]]
}

@test "effort cannot exceed role effort and xhigh is rejected" {
    run "$HOOK" <<< "$(claude_event coder sonnet high)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"effort"* ]]
    run "$HOOK" <<< "$(claude_event coder sonnet xhigh)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"low, medium, or high"* ]]
    run "$HOOK" <<< "$(claude_event reviewer opus low)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "missing, malformed, and traversal roles are denied" {
    run "$HOOK" <<< "$(claude_event absent)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"definition"* ]]
    printf '%s\n' 'model: [broken' >"$HOME/.claude/agents/broken.md"
    run "$HOOK" <<< "$(claude_event broken)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"definition"* ]]
    run "$HOOK" <<< "$(claude_event ../coder)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"role"* ]]
}

@test "Codex requires a bounded fork and rejects full inheritance" {
    run "$HOOK" <<< "$(codex_event coder gpt-5.6-sol medium all)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"fork_turns"* ]]
    run "$HOOK" <<< "$(codex_event coder gpt-5.6-sol medium none)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "Codex unavailable-specialist fallback needs explicit supported settings" {
    run "$HOOK" <<< "$(codex_event default gpt-5.6-sol medium none)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run "$HOOK" <<< "$(codex_event default gpt-5.6-sol medium 1)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"fork_turns"* ]]
    run "$HOOK" <<< "$(codex_event worker '' '' none)"
    [ "$status" -eq 0 ]
    assert_denied
    [[ "$output" == *"explicit"* ]]
}


@test "Codex guard reads the real rendered coder definition" {
    source "$REAL_DOTFILES_DIR/.sync-lib.sh"
    _cz_render_codex_agent "$REAL_DOTFILES_DIR/agents/registry.yaml" coder "$REAL_DOTFILES_DIR" "$HOME/.codex/agents/coder.toml"
    [ "$(yq -p=toml -oy -r '.model' "$HOME/.codex/agents/coder.toml")" = gpt-5.6-sol ]
    [ "$(yq -p=toml -oy -r '.model_reasoning_effort' "$HOME/.codex/agents/coder.toml")" = medium ]
    run env DOTFILES_HARNESS=codex "$HOOK" <<< "$(codex_event coder gpt-5.6-sol medium none)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
@test "malformed input returns protocol error" {
    run "$HOOK" <<< '{not-json'
    [ "$status" -eq 2 ]
    [[ "$output" == *"valid JSON"* ]]
}

@test "registry and Claude deployment wire the guard and shared asset" {
    grep -Fq 'agent-routing-guard.sh' "$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"
    grep -Fq 'agent-routing-guard.js' "$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"
    grep -Fq 'matcher: "Agent|Task|spawn_agent"' "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
    grep -Fq 'DOTFILES_HARNESS=claude' "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml"
}
