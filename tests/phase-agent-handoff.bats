#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2016,SC2034,SC2317
# Tests for the phase-agent cross-phase handoff convention documented in
# agents/preamble.md and agents/agent_definitions/{explorer,researcher,reviewer,coder}.md.
# Locks the spec's core invariant: the four-field handoff block must stay
# byte-identical across every file that carries it (no schema drift), plus
# the coder fan-out rule and per-agent convention presence.

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

@test "handoff block is byte-identical across preamble and the four phase-agent bodies" {
    local pre exp res rev cod
    pre=$(block_sha "$PREAMBLE")
    exp=$(block_sha "$AGENTS_DIR/agent_definitions/explorer.md")
    res=$(block_sha "$AGENTS_DIR/agent_definitions/researcher.md")
    rev=$(block_sha "$AGENTS_DIR/agent_definitions/reviewer.md")
    cod=$(block_sha "$AGENTS_DIR/agent_definitions/coder.md")

    # A non-empty hash proves the block was actually found in each file
    # (block_sha emits nothing when grep matches nothing).
    [[ -n "$pre" ]] || { echo "no handoff block in preamble.md" >&2; return 1; }
    [[ "$exp" == "$pre" ]] || { echo "explorer block drifted from preamble ($exp != $pre)" >&2; return 1; }
    [[ "$res" == "$pre" ]] || { echo "researcher block drifted from preamble ($res != $pre)" >&2; return 1; }
    [[ "$rev" == "$pre" ]] || { echo "reviewer block drifted from preamble ($rev != $pre)" >&2; return 1; }
    [[ "$cod" == "$pre" ]] || { echo "coder block drifted from preamble ($cod != $pre)" >&2; return 1; }
}

@test "preamble documents the one-coder-default fan-out rule with the disjointness precondition" {
    run grep -q '### Coder fan-out' "$PREAMBLE"
    assert_success
    run grep -qi 'Default to one coder' "$PREAMBLE"
    assert_success
    run grep -qi 'file-disjoint and independent' "$PREAMBLE"
    assert_success
}

@test "preamble documents the cross-phase handoff section" {
    run grep -q '### Cross-phase handoff' "$PREAMBLE"
    assert_success
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

@test "phase handoff defers role-specific turn caps to the registry" {
    local registry="$AGENTS_DIR/registry.yaml"

    run grep -Fq 'Turn caps are role-specific and come from `agents/registry.yaml` `maxTurns`' "$PREAMBLE"
    assert_success
    run grep -Fq '130k tokens / 100 turns' "$PREAMBLE"
    assert_failure

    run yq '.agents.reviewer.maxTurns' "$registry"
    [[ "$output" == "50" ]] || { echo "reviewer maxTurns drifted: $output" >&2; return 1; }
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

@test "coder sizing thresholds are heuristics and blocking requires a concrete split" {
    local coder="$AGENTS_DIR/agent_definitions/coder.md"

    run grep -Fq 'Dispatch sizing — heuristics, not refusal rules.' "$PREAMBLE"
    assert_success
    run grep -Fq 'only when you can name a concrete natural split' "$coder"
    assert_success
    run grep -Fq 'it will not fit' "$coder"
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
# coder that edits only through tilth (cheez-write). Lock those tool-surface contracts in the
# registry so they can't silently drift. The same metadata renders to Claude,
# Codex, opencode, and Copilot CLI; Copilot ignores model overrides.
@test "phase agents declare model intent for model-aware harnesses" {
    local registry="$AGENTS_DIR/registry.yaml"
    for agent in explorer researcher reviewer coder; do
        for harness in claude codex opencode; do
            run yq ".agents.${agent}.models.${harness}" "$registry"
            assert_success
            [[ "$output" != "null" ]] || { echo "$agent missing $harness model" >&2; return 1; }
        done
        run yq ".agents.${agent}.models.copilot" "$registry"
        assert_success
        [[ "$output" == "null" ]] || { echo "$agent must not set Copilot model (renderer ignores it)" >&2; return 1; }
    done
}

@test "phase-agent skill references use installed (un-namespaced) names and stay scoped" {
    local registry="$AGENTS_DIR/registry.yaml"

    run yq '.agents.explorer.skills | join(" ")' "$registry"
    assert_success
    [[ "$output" == "cheez-search cheez-read" ]] || { echo "explorer skills drifted: $output" >&2; return 1; }

    for agent in researcher reviewer coder; do
        run yq ".agents.${agent}.skills | join(\" \")" "$registry"
        assert_success
        [[ "$output" != *cheese-flow:* ]] || { echo "$agent still references cheese-flow" >&2; return 1; }
        [[ "$output" != *scout* ]] || { echo "$agent should not carry scout" >&2; return 1; }
    done
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

@test "coder denies native edit tools and subagent fan-out in the registry" {
    local registry="$AGENTS_DIR/registry.yaml"
    # Aggressive lockdown (session-analytics evidence): coder mutates the tree
    # exclusively through cheez-write (tilth), so native edit/search tools are denied.
    # Exact membership per tool: a substring check for Edit would match NotebookEdit.
    for tool in Edit Write NotebookEdit Grep Glob Agent; do
        run yq -e ".agents.coder.disallowedTools[] | select(. == \"$tool\")" "$registry"
        [[ "$status" -eq 0 ]] || { echo "coder must deny $tool (edits go through cheez-write)" >&2; return 1; }
    done
    # Read is kept (see decision 5).
    run yq -e '.agents.coder.disallowedTools[] | select(. == "Read")' "$registry"
    [[ "$status" -ne 0 ]] || { echo "coder must keep native Read" >&2; return 1; }
}
