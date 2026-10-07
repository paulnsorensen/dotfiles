#!/usr/bin/env bats
# Tests for bin/wt — worktree creation without a harness-specific branch name.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
    TMPROOT="$(mktemp -d)"
    REPO="$TMPROOT/repo"
    HOME="$TMPROOT/home"
    export HOME DOTFILES_DIR
    mkdir -p "$REPO" "$HOME"

    git -C "$REPO" init -b main -q
    git -C "$REPO" config user.email t@t.test
    git -C "$REPO" config user.name tester
    git -C "$REPO" commit --allow-empty -q -m init

    local origin="$TMPROOT/origin.git"
    git init --bare -b main -q "$origin"
    git -C "$REPO" remote add origin "$origin"
    git -C "$REPO" push -q origin main
    git -C "$REPO" remote set-head origin main
}

teardown() {
    rm -rf "$TMPROOT"
}

@test "creates a generic branch from the current branch" {
    cd "$REPO"
    run "$DOTFILES_DIR/bin/wt" -m feature
    [ "$status" -eq 0 ]
    run git -C "$REPO" show-ref --verify --quiet refs/heads/worktree/feature
    [ "$status" -eq 0 ]
}

@test "creates a generic branch from origin's default branch" {
    cd "$REPO"
    run "$DOTFILES_DIR/bin/wt" -o feature
    [ "$status" -eq 0 ]
    run git -C "$REPO" show-ref --verify --quiet refs/heads/worktree/feature
    [ "$status" -eq 0 ]
}

@test "nested worktree links its Claude project past the parent's symlink" {
    local projects="$HOME/.claude/projects"
    REPO="$(cd -P "$REPO" && pwd)"
    mkdir -p "$projects/${REPO//[\/.]/-}"
    cd "$REPO"
    run "$DOTFILES_DIR/bin/wt" parent
    [ "$status" -eq 0 ]
    cd "$REPO/.worktrees/parent"
    run "$DOTFILES_DIR/bin/wt" child
    [ "$status" -eq 0 ]
    local child_key="$REPO/.worktrees/parent/.worktrees/child"
    child_key="${child_key//[\/.]/-}"
    [ "$(readlink "$projects/$child_key")" = "$(cd -P "$projects/${REPO//[\/.]/-}" && pwd)" ]
}

@test "nested worktree names the owner of a colliding branch" {
    REPO="$(cd -P "$REPO" && pwd)"
    cd "$REPO"
    run "$DOTFILES_DIR/bin/wt" shared
    [ "$status" -eq 0 ]
    run "$DOTFILES_DIR/bin/wt" parent
    [ "$status" -eq 0 ]
    cd "$REPO/.worktrees/parent"
    run "$DOTFILES_DIR/bin/wt" shared
    [ "$status" -ne 0 ]
    [[ "$output" == *"already checked out at $REPO/.worktrees/shared"* ]]
    [ ! -d "$REPO/.worktrees/parent/.worktrees/shared" ]
}
