#!/usr/bin/env bats
# Tests for bin/ccw-check — worktree permission and sandbox checks.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
    TMPROOT="$(mktemp -d)"
    TMPROOT="$(cd -P "$TMPROOT" && pwd)"
    REPO="$TMPROOT/repo"
    HOME="$TMPROOT/home"
    export HOME DOTFILES_DIR
    mkdir -p "$REPO" "$HOME/.claude/projects/${REPO//[\/.]/-}"
    git -C "$REPO" init -b main -q
    git -C "$REPO" config user.email t@t.test
    git -C "$REPO" config user.name tester
    git -C "$REPO" commit --allow-empty -q -m init
    cd "$REPO" && "$DOTFILES_DIR/bin/wt" parent >/dev/null 2>&1
    cd "$REPO/.worktrees/parent" && "$DOTFILES_DIR/bin/wt" child >/dev/null 2>&1
}

teardown() {
    rm -rf "$TMPROOT"
}

@test "auto-detects a top-level worktree from a subdir" {
    mkdir -p "$REPO/.worktrees/parent/sub"
    cd "$REPO/.worktrees/parent/sub"
    run "$DOTFILES_DIR/bin/ccw-check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checking worktree: parent"* ]]
    [[ "$output" == *"Permission symlink → main repo"* ]]
}

@test "auto-detects a nested worktree from inside it" {
    cd "$REPO/.worktrees/parent/.worktrees/child"
    run "$DOTFILES_DIR/bin/ccw-check"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Checking worktree: child"* ]]
    [[ "$output" == *"Permission symlink → main repo"* ]]
}

@test "accepts a nested worktree linked through its parent's symlink" {
    local projects="$HOME/.claude/projects"
    local child_key="$REPO/.worktrees/parent/.worktrees/child"
    local parent_key="$REPO/.worktrees/parent"
    child_key="${child_key//[\/.]/-}"
    parent_key="${parent_key//[\/.]/-}"
    rm "$projects/$child_key"
    ln -s "$projects/$parent_key" "$projects/$child_key"
    cd "$REPO/.worktrees/parent"
    run "$DOTFILES_DIR/bin/ccw-check" child
    [ "$status" -eq 0 ]
    [[ "$output" == *"Permission symlink → main repo"* ]]
}

@test "flags a dangling project symlink" {
    local projects="$HOME/.claude/projects"
    local child_key="$REPO/.worktrees/parent/.worktrees/child"
    child_key="${child_key//[\/.]/-}"
    rm "$projects/$child_key"
    ln -s "$projects/missing" "$projects/$child_key"
    cd "$REPO/.worktrees/parent"
    run "$DOTFILES_DIR/bin/ccw-check" child
    [ "$status" -ne 0 ]
    [[ "$output" == *"unexpected target"* ]]
}

@test "does not treat a plain clone under a .worktrees dir as a linked worktree" {
    git clone -q "$REPO" "$TMPROOT/.worktrees/clone"
    cd "$TMPROOT/.worktrees/clone"
    run "$DOTFILES_DIR/bin/ccw-check"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Usage: ccw-check <slug>"* ]]
}
