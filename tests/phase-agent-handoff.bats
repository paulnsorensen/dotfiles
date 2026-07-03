#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
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

# The descriptions promise read-only phase agents that cannot recurse, and a
# coder that keeps the write surface. Lock those tool-surface contracts in the
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
    # explorer + reviewer are fully read-only: deny Write and Agent.
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
    [[ "$output" == *Edit* ]] || { echo "researcher must deny Edit" >&2; return 1; }
    [[ "$output" == *Agent* ]] || { echo "researcher must deny Agent (no subagent fan-out)" >&2; return 1; }
}

@test "coder denies native edit tools and subagent fan-out in the registry" {
    local registry="$AGENTS_DIR/registry.yaml"
    run yq '.agents.coder.disallowedTools' "$registry"
    assert_success
    # Aggressive lockdown (session-analytics evidence): coder mutates the tree
    # exclusively through cheez-write (tilth), so native edit/search tools are denied.
    for tool in Edit Write NotebookEdit Grep Glob; do
        [[ "$output" == *"$tool"* ]] || { echo "coder must deny $tool (edits go through cheez-write)" >&2; return 1; }
    done
    # Read is kept (see decision 5), and Agent denied (level-1 subagent, no fan-out).
    [[ "$output" != *Read* ]] || { echo "coder must keep native Read" >&2; return 1; }
    [[ "$output" == *Agent* ]] || { echo "coder must deny Agent (no subagent fan-out)" >&2; return 1; }
}
