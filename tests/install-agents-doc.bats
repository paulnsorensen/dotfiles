#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for chezmoi/lib/install-agents-doc.sh — copies a single shared agents
# doc to one or more harness-specific target paths, replacing any pre-existing
# symlink (legacy claude/.sync layout) with a real file.

load test_helper

setup() {
    setup_test_env
    INSTALLER="$REAL_DOTFILES_DIR/chezmoi/lib/install-agents-doc.sh"
    SRC="$TEST_HOME/agents/AGENTS.md"
    mkdir -p "$TEST_HOME/agents"
    cat > "$SRC" <<'DOC'
# Shared agent preferences
This file is the source of truth.
DOC
}

teardown() { teardown_test_env; }

@test "install-agents-doc.sh prints usage and exits 2 with < 2 args" {
    run bash "$INSTALLER"
    [[ "$status" -eq 2 ]]
    assert_output_contains "Usage:"
    run bash "$INSTALLER" "$SRC"
    [[ "$status" -eq 2 ]]
}

@test "install-agents-doc.sh fails when source file is missing" {
    run bash "$INSTALLER" "$TEST_HOME/does-not-exist.md" "$TEST_HOME/.claude/CLAUDE.md"
    assert_failure
    assert_output_contains "source not found"
}

@test "install-agents-doc.sh copies to a single target path" {
    local target="$TEST_HOME/.claude/CLAUDE.md"
    run bash "$INSTALLER" "$SRC" "$target"
    assert_success
    assert_output_contains "Copied AGENTS.md -> $target"
    assert_file_exists "$target"
    [[ ! -L "$target" ]]   # plain file, not a symlink
    grep -q 'source of truth' "$target"
}

@test "install-agents-doc.sh fans out to multiple targets in one call" {
    local t1="$TEST_HOME/.claude/CLAUDE.md"
    local t2="$TEST_HOME/.codex/AGENTS.md"
    run bash "$INSTALLER" "$SRC" "$t1" "$t2"
    assert_success
    assert_file_exists "$t1"
    assert_file_exists "$t2"
    diff -q "$t1" "$t2"      # identical content in both targets
}

@test "install-agents-doc.sh replaces a legacy symlink with a real copy" {
    local target="$TEST_HOME/.claude/CLAUDE.md"
    local legacy="$TEST_HOME/legacy-source.md"
    echo "# legacy source" > "$legacy"
    mkdir -p "$(dirname "$target")"
    ln -s "$legacy" "$target"
    [[ -L "$target" ]]
    run bash "$INSTALLER" "$SRC" "$target"
    assert_success
    [[ ! -L "$target" ]]                             # symlink replaced
    grep -q 'source of truth' "$target"              # contents come from SRC
    grep -q 'legacy source'   "$legacy"              # legacy source untouched
}

@test "install-agents-doc.sh overwrites an existing real file" {
    local target="$TEST_HOME/.claude/CLAUDE.md"
    mkdir -p "$(dirname "$target")"
    echo "stale content" > "$target"
    run bash "$INSTALLER" "$SRC" "$target"
    assert_success
    grep -q 'source of truth' "$target"
    ! grep -q 'stale content' "$target"
}

@test "install-agents-doc.sh creates the parent directory if missing" {
    local target="$TEST_HOME/freshly-created/sub/CLAUDE.md"
    [[ ! -d "$(dirname "$target")" ]]
    run bash "$INSTALLER" "$SRC" "$target"
    assert_success
    assert_file_exists "$target"
}
