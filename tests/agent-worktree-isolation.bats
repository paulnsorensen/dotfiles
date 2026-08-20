#!/usr/bin/env bats
# Guard against the worktree-isolation default living only inside saved
# workflows (issue #736). The intent — a spawned write-capable agent gets its
# own git worktree — must be stated as a rule every agent reads, not re-encoded
# per call site. The rule lives in agents/AGENTS.md (copied to every harness on
# `dots sync`) and is named in the write-capable coder agent definition, paired
# with base-ref pinning and the named opt-out exceptions.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SHARED_DOC="$DOTFILES_DIR/agents/AGENTS.md"
CODER_DEF="$DOTFILES_DIR/agents/agent_definitions/coder.md"

@test "agents/AGENTS.md states the worktree-isolation default as a rule" {
    grep -qi 'isolation' "$SHARED_DOC"
    grep -qi 'worktree' "$SHARED_DOC"
}

@test "agents/AGENTS.md pins the base ref against the moving refs it replaces" {
    grep -Eqi 'HEAD~|origin/main' "$SHARED_DOC"
}

@test "agents/AGENTS.md writes down the worktree opt-out exceptions" {
    grep -qi 'barrier' "$SHARED_DOC"
    grep -Eqi 'lcov|Nx cache|node_modules' "$SHARED_DOC"
}

@test "the write-capable coder agent definition names worktree isolation" {
    grep -qi 'worktree' "$CODER_DEF"
}
