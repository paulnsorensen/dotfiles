#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2016,SC2034,SC2317
# Tests for the phase-agent body contracts in
# agents/agent_definitions/{explorer,researcher,reviewer,coder}.md.
# Locks the four-field handoff schema across every body that carries it,
# plus the coder's role-owned workflow and tool-surface contracts.

load test_helper

AGENTS_DIR=""
PREAMBLE=""

setup() {
    AGENTS_DIR="$REAL_DOTFILES_DIR/agents"
    PREAMBLE="$AGENTS_DIR/preamble.md"
}

# Extract the four-line handoff block (status/next/artifact/orientation) and
# hash it, so two files agree only when the block is byte-identical.
block_sha() {
    local block
    block=$(grep -A3 '^status: ok | blocked:' "$1" | head -4)
    # shasum of empty input is a non-empty SHA, which would let a block removed
    # from every file slip past the -n guard below. Emit nothing when grep
    # matched nothing so the guard (and the equality checks) catch a missing block.
    [[ -n "$block" ]] || return 0
    printf '%s\n' "$block" | shasum | awk '{print $1}'
}

@test "handoff block is byte-identical across the four phase-agent bodies" {
    local exp res rev cod
    exp=$(block_sha "$AGENTS_DIR/agent_definitions/explorer.md")
    res=$(block_sha "$AGENTS_DIR/agent_definitions/researcher.md")
    rev=$(block_sha "$AGENTS_DIR/agent_definitions/reviewer.md")
    cod=$(block_sha "$AGENTS_DIR/agent_definitions/coder.md")

    # Explorer is the reference body; a non-empty hash proves the block exists.
    [[ -n "$exp" ]] || { echo "no handoff block in explorer.md" >&2; return 1; }
    [[ "$res" == "$exp" ]] || { echo "researcher block drifted from explorer ($res != $exp)" >&2; return 1; }
    [[ "$rev" == "$exp" ]] || { echo "reviewer block drifted from explorer ($rev != $exp)" >&2; return 1; }
    [[ "$cod" == "$exp" ]] || { echo "coder block drifted from explorer ($cod != $exp)" >&2; return 1; }
}

@test "all four phase-agent bodies carry a Handoff section" {
    for agent in explorer researcher reviewer coder; do
        run grep -q '^## Handoff' "$AGENTS_DIR/agent_definitions/$agent.md"
        assert_success
    done
}

@test "coder body documents the scoped-slice contract" {
    run grep -qi 'scoped .slice.' "$AGENTS_DIR/agent_definitions/coder.md"
    assert_success
}

@test "coder routes workspace file operations through tilth directly" {
    local coder="$AGENTS_DIR/agent_definitions/coder.md"

    for tool in tilth_search tilth_read tilth_write tilth_diff; do
        run grep -Fq "\`$tool\`" "$coder"
        assert_success
    done
    for retired in cheez-search cheez-read cheez-write; do
        run grep -Fq "$retired" "$coder"
        assert_failure
    done
}

@test "phase-agent turn caps are owned by the registry and role bodies" {
    local registry="$AGENTS_DIR/registry.yaml"

    run yq '.agents.reviewer.maxTurns' "$registry"
    [[ "$output" == "50" ]] || { echo "reviewer maxTurns drifted: $output" >&2; return 1; }
    run grep -Fq 'The registry'"'"'s `.agents.reviewer.maxTurns` is the role-limit source of truth.' "$AGENTS_DIR/agent_definitions/reviewer.md"
    assert_success

    run yq '.agents.coder.maxTurns' "$registry"
    [[ "$output" == "100" ]] || { echo "coder maxTurns drifted: $output" >&2; return 1; }
    run grep -Fq '130k tokens / 100 turns' "$AGENTS_DIR/agent_definitions/coder.md"
    assert_success
}

@test "runtime phase prompts keep rules but not dispatch analytics" {
    local prompt
    for prompt in "$PREAMBLE" "$AGENTS_DIR/agent_definitions/coder.md"; do
        for metric in '207 real dispatches' 'Measured coverage today' '37% of real coder runs' 'Real runs route only half'; do
            run grep -Fq "$metric" "$prompt"
            assert_failure
        done
    done
}

@test "coder owns its sizing heuristics and concrete-split blocking rule" {
    local coder="$AGENTS_DIR/agent_definitions/coder.md"

    run grep -Fq '**Sizing heuristics.**' "$coder"
    assert_success
    run grep -Fq 'only when you can name a concrete natural split' "$coder"
    assert_success
    run grep -Fq 'it will not fit' "$coder"
    assert_failure
}

@test "coder defers qualifying taste-tests with a self-contained reviewer handoff" {
    local coder="$AGENTS_DIR/agent_definitions/coder.md"

    for contract in '>1 file or adds public surface' \
        'taste_test: deferred-to-orchestrator' \
        'next: reviewer' \
        'Review mode: taste-test' \
        'contract, diff, cut-test list, and locked decisions' \
        'do not return `next: done` while deferred'; do
        run grep -Fqi "$contract" "$coder"
        assert_success
    done
    run grep -Fq '.cheese/cook/<slug>.md' "$coder"
    assert_success
    run grep -Fq -- '- Production path: pass | revise' "$coder"
    assert_failure
    run grep -Fq 'two-round cap' "$coder"
    assert_failure
}

@test "reviewer dispatch selects an explicit output mode and defines both schemas" {
    local reviewer="$AGENTS_DIR/agent_definitions/reviewer.md"

    run grep -Fq 'Review mode: severity-report' "$reviewer"
    assert_success
    run grep -Fq 'Review mode: taste-test' "$reviewer"
    assert_success
    run grep -Fq 'Do not infer the mode from words such as “lenses”' "$reviewer"
    assert_success
    run grep -Fq -- '- Drift: pass | revise — <evidence>' "$reviewer"
    assert_success
    run grep -Fq -- '- Locked decision: pass | halt — <evidence>' "$reviewer"
    assert_success
    run grep -Fq 'Review mode: taste-test' "$PREAMBLE"
    assert_success
    run grep -Fq 'Review mode: severity-report' "$PREAMBLE"
    assert_success
}

@test "reviewer may write only its own artifact through cheez-write" {
    local registry="$AGENTS_DIR/registry.yaml"

    run yq -e '.agents.reviewer.skills[] | select(. == "cheez-write")' "$registry"
    assert_success
    run yq -e '.agents.reviewer.disallowedTools[] | select(. == "Write")' "$registry"
    assert_success
    run grep -Fq 'write only your own `.cheese/` artifact through `cheez-write`' "$AGENTS_DIR/agent_definitions/reviewer.md"
    assert_success
}

# The descriptions promise read-only phase agents that cannot recurse, and a
# coder that edits only through tilth. Lock those tool-surface contracts in the
# registry so they cannot silently drift. The same metadata renders to Claude,
# Codex, opencode, and Copilot CLI; Copilot ignores model overrides.
# Asserted against the RESOLVED view (`ap agents-json`), not the registry text:
# claude/codex now arrive from the agent's `tier:` via agents/models.yaml, so
# reading `.models.claude` off the registry would see null and prove nothing.
# What matters is that a model reaches the renderer, wherever it came from.
@test "phase agents declare model intent for model-aware harnesses" {
    local resolved
    resolved=$(uv run --project "$REAL_DOTFILES_DIR/agent-profile" --frozen \
        -m agent_profile agents-json "$AGENTS_DIR/registry.yaml") \
        || { echo "ap agents-json failed" >&2; return 1; }
    local agent harness model
    for agent in explorer researcher reviewer coder; do
        for harness in claude codex opencode; do
            model=$(jq -r --arg a "$agent" --arg h "$harness" \
                '.[] | select(.name == $a) | .models[$h] // "null"' <<<"$resolved")
            [[ "$model" != "null" && -n "$model" ]] \
                || { echo "$agent missing $harness model" >&2; return 1; }
        done
        model=$(jq -r --arg a "$agent" \
            '.[] | select(.name == $a) | .models.copilot // "null"' <<<"$resolved")
        [[ "$model" == "null" ]] \
            || { echo "$agent must not set Copilot model (renderer ignores it)" >&2; return 1; }
    done
}

@test "phase-agent skill references use installed names and stay scoped" {
    local registry="$AGENTS_DIR/registry.yaml"

    run yq '.agents.explorer.skills | join(" ")' "$registry"
    assert_success
    [[ "$output" == "cheez-search cheez-read" ]] || { echo "explorer skills drifted: $output" >&2; return 1; }

    for agent in researcher reviewer; do
        run yq ".agents.${agent}.skills | join(\" \")" "$registry"
        assert_success
        [[ "$output" != *cheese-flow:* ]] || { echo "$agent still references cheese-flow" >&2; return 1; }
        [[ "$output" != *scout* ]] || { echo "$agent should not carry scout" >&2; return 1; }
    done

    run yq '.agents.coder.skills | join(" ")' "$registry"
    assert_success
    [[ "$output" == "cook press cure de-slop tdd-assertions commit" ]] || { echo "coder skills drifted: $output" >&2; return 1; }
}

@test "read-only phase agents deny code edits and subagent fan-out in the registry" {
    local registry="$AGENTS_DIR/registry.yaml"
    # explorer + reviewer deny native Write and subagent fan-out; reviewer writes only its own artifact through cheez-write.
    for agent in explorer reviewer; do
        run yq ".agents.${agent}.disallowedTools" "$registry"
        assert_success
        [[ "$output" == *Write* ]] || { echo "$agent must deny Write" >&2; return 1; }
        [[ "$output" == *Agent* ]] || { echo "$agent must deny Agent (no subagent fan-out)" >&2; return 1; }
    done
    # researcher intentionally keeps Write (it writes .cheese/research/), but
    # must still deny code edits and fan-out.
    run yq '.agents.researcher.disallowedTools' "$registry"
    assert_success
    [[ "$output" == *Agent* ]] || { echo "researcher must deny Agent (no subagent fan-out)" >&2; return 1; }
    # Exact membership: a substring check for Edit would match NotebookEdit.
    run yq -e '.agents.researcher.disallowedTools[] | select(. == "Edit")' "$registry"
    [[ "$status" -eq 0 ]] || { echo "researcher must deny Edit" >&2; return 1; }
}

@test "coder denies native edit/search tools and subagent fan-out in the registry" {
    local registry="$AGENTS_DIR/registry.yaml"
    # Exact membership per tool: a substring check for Edit would match NotebookEdit.
    for tool in Edit Write NotebookEdit Grep Glob Agent; do
        run yq -e ".agents.coder.disallowedTools[] | select(. == \"$tool\")" "$registry"
        [[ "$status" -eq 0 ]] || { echo "coder must deny $tool (workspace file operations go through tilth)" >&2; return 1; }
    done
    # The harness may expose native Read, but the coder body routes reads through tilth_read.
    run yq -e '.agents.coder.disallowedTools[] | select(. == "Read")' "$registry"
    [[ "$status" -ne 0 ]] || { echo "coder must keep native Read available" >&2; return 1; }
}
