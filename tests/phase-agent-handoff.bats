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
    grep -A3 '^status: ok | blocked:' "$1" | head -4 | shasum | awk '{print $1}'
}

@test "handoff block is byte-identical across preamble and the three full-block agent bodies" {
    local pre exp res rev
    pre=$(block_sha "$PREAMBLE")
    exp=$(block_sha "$AGENTS_DIR/agent_definitions/explorer.md")
    res=$(block_sha "$AGENTS_DIR/agent_definitions/researcher.md")
    rev=$(block_sha "$AGENTS_DIR/agent_definitions/reviewer.md")

    # A non-empty hash proves the block was actually found in each file.
    [[ -n "$pre" ]] || { echo "no handoff block in preamble.md" >&2; return 1; }
    [[ "$exp" == "$pre" ]] || { echo "explorer block drifted from preamble ($exp != $pre)" >&2; return 1; }
    [[ "$res" == "$pre" ]] || { echo "researcher block drifted from preamble ($res != $pre)" >&2; return 1; }
    [[ "$rev" == "$pre" ]] || { echo "reviewer block drifted from preamble ($rev != $pre)" >&2; return 1; }
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

@test "explorer, researcher, and reviewer bodies each carry a Handoff section" {
    for agent in explorer researcher reviewer; do
        run grep -q '^## Handoff' "$AGENTS_DIR/agent_definitions/$agent.md"
        assert_success
    done
}

@test "coder body documents the scoped-slice contract" {
    run grep -qi 'scoped .slice.' "$AGENTS_DIR/agent_definitions/coder.md"
    assert_success
}
