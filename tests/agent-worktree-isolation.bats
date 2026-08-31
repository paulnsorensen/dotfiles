#!/usr/bin/env bats
# Guard against the worktree-isolation default living only inside saved
# workflows (issue #736). The default — a spawned write-capable agent gets its
# own git worktree, pinned to a base SHA — must be stated where every agent
# reads it: the Rules in agents/AGENTS.md (copied to every harness on
# `dots sync`) and the write-capable coder agent definition.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SHARED_DOC="$DOTFILES_DIR/agents/AGENTS.md"
CODER_DEF="$DOTFILES_DIR/agents/agent_definitions/coder.md"

@test "agents/AGENTS.md states the worktree-isolation default as a rule" {
    grep -qi 'isolat' "$SHARED_DOC"
    grep -qi 'worktree' "$SHARED_DOC"
}

@test "agents/AGENTS.md pins spawned agents to a base SHA" {
    grep -qi 'base SHA' "$SHARED_DOC"
}

@test "agents/AGENTS.md names the worktree opt-out exceptions" {
    grep -qi 'barrier' "$SHARED_DOC"
    grep -qi 'cold dependencies' "$SHARED_DOC"
}

@test "the coder agent definition names worktree isolation and base-sha pinning" {
    grep -qi 'worktree' "$CODER_DEF"
    grep -Eqi 'base (commit )?SHA' "$CODER_DEF"
}
