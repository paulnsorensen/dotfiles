#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034
#
# Tests for chezmoi/lib/install-claude-assets.sh — deploys claude's
# commands/hooks/reference/workflows dirs into ~/.claude as ONE-WAY COPIES
# (not symlinks), so runtime writes never leak back into the dotfiles repo.
# Manifest-tracked: drops items removed from the repo, preserves user files,
# and self-migrates a legacy symlink target to a real dir.

load test_helper

INSTALL_SCRIPT="$REAL_DOTFILES_DIR/chezmoi/lib/install-claude-assets.sh"
MANIFEST=".dotfiles-managed-claude-assets"

# Build a hermetic fake claude/ source tree so tests don't depend on the
# live repo content.
setup() {
    setup_test_env
    export CLAUDE_HOME="$TEST_HOME/.claude"
    export SRC="$TEST_HOME/claude-src"
    mkdir -p "$SRC/commands" "$SRC/hooks" "$SRC/reference" "$SRC/workflows"
    echo "cmd-a" > "$SRC/commands/a.md"
    echo "cmd-b" > "$SRC/commands/b.md"
    echo "hook" > "$SRC/hooks/guard.js"
    echo "ref"  > "$SRC/reference/doc.md"
    echo "wf"   > "$SRC/workflows/flow.js"
}

teardown() {
    teardown_test_env
}

@test "install-claude-assets: missing source dir exits non-zero" {
    run "$INSTALL_SCRIPT" "$TEST_HOME/nope" "$CLAUDE_HOME"
    assert_failure
}

@test "install-claude-assets: copies all four collections" {
    run "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    assert_success
    [[ -f "$CLAUDE_HOME/commands/a.md" ]]
    [[ -f "$CLAUDE_HOME/commands/b.md" ]]
    [[ -f "$CLAUDE_HOME/hooks/guard.js" ]]
    [[ -f "$CLAUDE_HOME/reference/doc.md" ]]
    [[ -f "$CLAUDE_HOME/workflows/flow.js" ]]
}

@test "install-claude-assets: targets are real dirs, not symlinks" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    for d in commands hooks reference workflows; do
        # `|| return 1` is required: a bare `[[ ]]` in a loop reports only the
        # last iteration's status, masking a real symlink on an earlier dir.
        [[ -d "$CLAUDE_HOME/$d" && ! -L "$CLAUDE_HOME/$d" ]] || return 1
    done
}

@test "install-claude-assets: writes a manifest per collection" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ -f "$CLAUDE_HOME/commands/$MANIFEST" ]]
    grep -Fxq "a.md" "$CLAUDE_HOME/commands/$MANIFEST"
    grep -Fxq "b.md" "$CLAUDE_HOME/commands/$MANIFEST"
}

@test "install-claude-assets: copy does NOT leak writes back to source" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    touch "$CLAUDE_HOME/commands/runtime-junk.md"
    [[ ! -e "$SRC/commands/runtime-junk.md" ]]
}

@test "install-claude-assets: self-migrates a legacy symlink target (all collections)" {
    # Simulate the old sync: EVERY managed dir is a symlink into the repo.
    # Migration runs per-collection, so all four must be exercised — testing
    # only `commands` would let a typo in the loop body pass unnoticed.
    mkdir -p "$CLAUDE_HOME"
    for d in commands hooks reference workflows; do
        ln -s "$SRC/$d" "$CLAUDE_HOME/$d"
        [[ -L "$CLAUDE_HOME/$d" ]] || return 1
    done

    run "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    assert_success
    assert_output_contains "Removed legacy"
    for d in commands hooks reference workflows; do
        [[ -d "$CLAUDE_HOME/$d" && ! -L "$CLAUDE_HOME/$d" ]] || return 1
    done
    [[ -f "$CLAUDE_HOME/commands/a.md" ]]
    [[ -f "$CLAUDE_HOME/hooks/guard.js" ]]
    [[ -f "$CLAUDE_HOME/workflows/flow.js" ]]
}

@test "install-claude-assets: drops items removed from the repo" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ -f "$CLAUDE_HOME/commands/b.md" ]]
    # Remove b.md from source, re-run — it should disappear from the target.
    rm "$SRC/commands/b.md"
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ ! -e "$CLAUDE_HOME/commands/b.md" ]]
    [[ -f "$CLAUDE_HOME/commands/a.md" ]]
}

@test "install-claude-assets: preserves user-authored files not in manifest" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    echo "mine" > "$CLAUDE_HOME/commands/user-cmd.md"
    # Re-run: the user file is untouched because it was never in the manifest.
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ -f "$CLAUDE_HOME/commands/user-cmd.md" ]]
    [[ "$(cat "$CLAUDE_HOME/commands/user-cmd.md")" == "mine" ]]
}

@test "install-claude-assets: idempotent re-run leaves content stable" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    run "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    assert_success
    [[ -f "$CLAUDE_HOME/commands/a.md" ]]
    [[ -f "$CLAUDE_HOME/workflows/flow.js" ]]
}

@test "install-claude-assets: re-run propagates edited source content" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ "$(cat "$CLAUDE_HOME/commands/a.md")" == "cmd-a" ]]
    # The PR's central trade-off: edits to the repo source go live on the next
    # run (a `dots sync`). A regression that stopped re-copying changed files
    # would still leave the file present, so assert on CONTENT, not existence.
    echo "cmd-a-edited" > "$SRC/commands/a.md"
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ "$(cat "$CLAUDE_HOME/commands/a.md")" == "cmd-a-edited" ]]
}

@test "install-claude-assets: rejects traversal and bare-dot manifest entries safely" {
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    # A sibling of the managed dir that a `../` entry would target if unguarded.
    echo "keepme" > "$CLAUDE_HOME/evil"
    # Corrupt the manifest with entries the guard must reject: a path-traversal
    # escape, and a bare `.` (which `rm -rf -- "$target/."` would otherwise abort
    # on under `set -e`, taking the whole run down).
    printf '%s\n' "../evil" "." >> "$CLAUDE_HOME/commands/$MANIFEST"
    run "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    assert_success
    assert_output_contains "Skipped suspicious manifest entry: ../evil"
    assert_output_contains "Skipped suspicious manifest entry: ."
    [[ -f "$CLAUDE_HOME/evil" ]]
    [[ -f "$CLAUDE_HOME/commands/a.md" ]]
}

@test "install-claude-assets: drops a removed nested directory, not just files" {
    mkdir -p "$SRC/commands/sub"
    echo "nested" > "$SRC/commands/sub/c.md"
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ -f "$CLAUDE_HOME/commands/sub/c.md" ]]
    grep -Fxq "sub" "$CLAUDE_HOME/commands/$MANIFEST"
    # Remove the whole subdir from the source and re-run: rm -rf must drop the
    # directory entry, not only top-level files.
    rm -r "$SRC/commands/sub"
    "$INSTALL_SCRIPT" "$SRC" "$CLAUDE_HOME"
    [[ ! -e "$CLAUDE_HOME/commands/sub" ]]
    [[ -f "$CLAUDE_HOME/commands/a.md" ]]
}
