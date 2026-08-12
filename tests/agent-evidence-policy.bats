#!/usr/bin/env bats
# Regression coverage for issue #683: policy must make evidence a precondition,
# not a post-hoc confidence label.

load test_helper

setup() {
    setup_test_env
    INSTALLER="$REAL_DOTFILES_DIR/chezmoi/lib/install-agents-doc.sh"
    SOURCE="$REAL_DOTFILES_DIR/agents/AGENTS.md"
}

teardown() { teardown_test_env; }

@test "global evidence policy is enforced in source and rendered targets" {
    local claude="$TEST_HOME/.claude/CLAUDE.md"
    local codex="$TEST_HOME/.codex/AGENTS.md"
    run bash "$INSTALLER" "$SOURCE" "$claude" "$codex"
    assert_success

    for target in "$SOURCE" "$claude" "$codex"; do
        grep -Fq "A claim about what a file or system does must cite the exact source line range or verification command." "$target"
        grep -Fq "A claim about what it does not do requires a complete file read or a named exhaustive search" "$target"
        grep -Fq "Facts used as decision inputs or fork questions must be verified before the choice is presented." "$target"
        grep -Fq "Claims about build output, bundles, or packaging must be verified against the built artifact" "$target"
        grep -Fq "Treat tool output at its result cap as a lower bound; rerun with an explicit count before quoting it." "$target"
    done

    ! grep -Fq "Tag every opinion, recommendation, or factual claim inline" "$SOURCE"
    diff -q "$claude" "$codex"
    diff -q "$SOURCE" "$claude"
}
