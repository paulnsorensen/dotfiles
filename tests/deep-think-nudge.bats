#!/usr/bin/env bats
# Tests for the deep-think-nudge PreToolUse hook (Claude-only).
#   agents/hooks/deep-think-nudge.sh — self-contained bash gate
#
# WHY: hooks cannot change model/effort mid-session, so the ceiling of what is
# buildable for "go deeper on this reasoning-heavy skill" is a NUDGE injected as
# additionalContext. Its whole value is (a) firing ONLY for the four deep-
# synthesis skills (briesearch/culture/spec/mold), (b) firing ONLY when the
# session effort is below `high` — an already-deep session must never be
# nagged, and (c) never blocking or erroring a Skill call (fail-silent). The
# Skill tool_input field that holds the skill name is undocumented, so the hook
# reads skill/name/command defensively; the tests pin every shape.

load test_helper

HOOK="$REAL_DOTFILES_DIR/agents/hooks/deep-think-nudge.sh"

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Build a PreToolUse payload: $1=skill (via tool_input.skill), $2=effort.level.
payload() {
    local skill="$1" effort="$2"
    printf '{"hook_event_name":"PreToolUse","tool_name":"Skill","tool_input":{"skill":"%s"},"effort":{"level":"%s"}}' \
        "$skill" "$effort"
}

# ── Fires: deep skill + effort below high ──────────────────────────────────

@test "fires for mold at effort medium with the wheypoint+relaunch nudge" {
    run bash "$HOOK" <<<"$(payload mold medium)"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    # Valid JSON, correctly namespaced to PreToolUse.
    [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "PreToolUse" ]
    local ctx
    ctx="$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")"
    [[ "$ctx" == *"/wheypoint"* ]]
    [[ "$ctx" == *"xhigh"* ]]
    # No permission decision — a nudge must not gate the call.
    [ "$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$output")" = "none" ]
}

@test "fires for briesearch at effort low" {
    run bash "$HOOK" <<<"$(payload briesearch low)"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | wc -c)" -gt 1 ]
}

@test "fires for every one of the four target skills at medium" {
    for s in briesearch culture spec mold; do
        run bash "$HOOK" <<<"$(payload "$s" medium)"
        [ "$status" -eq 0 ]
        [ -n "$output" ] || { echo "expected nudge for $s" >&2; return 1; }
    done
}

# ── Silent: effort at or above high ────────────────────────────────────────

@test "silent for mold at effort high (already deep)" {
    run bash "$HOOK" <<<"$(payload mold high)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent for spec at effort xhigh" {
    run bash "$HOOK" <<<"$(payload spec xhigh)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent for culture at effort max" {
    run bash "$HOOK" <<<"$(payload culture max)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Silent: skill outside the target set ───────────────────────────────────

@test "silent for a non-target skill even at medium effort" {
    run bash "$HOOK" <<<"$(payload cook medium)"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "silent when the tool is not Skill" {
    run bash "$HOOK" <<<'{"tool_name":"Bash","tool_input":{"command":"mold"},"effort":{"level":"medium"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Effort source fallbacks ────────────────────────────────────────────────

@test "reads effort from CLAUDE_EFFORT env when payload omits it" {
    run env CLAUDE_EFFORT=medium bash "$HOOK" \
        <<<'{"tool_name":"Skill","tool_input":{"skill":"mold"}}'
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "silent when effort is unknowable (no payload effort, no env)" {
    run env -u CLAUDE_EFFORT bash "$HOOK" \
        <<<'{"tool_name":"Skill","tool_input":{"skill":"mold"}}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Defensive skill-name extraction (field name is undocumented) ───────────

@test "fires when the skill name arrives under tool_input.name" {
    run bash "$HOOK" <<<'{"tool_name":"Skill","tool_input":{"name":"mold"},"effort":{"level":"medium"}}'
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "fires when the skill name arrives under tool_input.command with args" {
    run bash "$HOOK" <<<'{"tool_name":"Skill","tool_input":{"command":"mold some/spec.md"},"effort":{"level":"medium"}}'
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "fires when the command form carries a leading slash" {
    run bash "$HOOK" <<<'{"tool_name":"Skill","tool_input":{"command":"/spec"},"effort":{"level":"low"}}'
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ── Fail-silent on garbage ─────────────────────────────────────────────────

@test "fail-silent on empty stdin" {
    run bash "$HOOK" <<<''
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "fail-silent on malformed JSON" {
    run bash "$HOOK" <<<'{not json'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
