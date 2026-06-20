#!/usr/bin/env bats
# Tests for bin/cc-session-name — collision-safe tmux session naming.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"

@test "worktree path -> <repo>-<slug>" {
    run cc-session-name "/home/u/Dev/myrepo/.worktrees/add-auth"
    [ "$status" -eq 0 ]
    [ "$output" = "myrepo-add-auth" ]
}

@test "dots and colons in the name become hyphens" {
    run cc-session-name "/home/u/Dev/repo.js/.worktrees/fix"
    [ "$output" = "repo-js-fix" ]
}

@test "nested worktree uses the immediate parent worktree + slug" {
    run cc-session-name "/home/u/Dev/dotfiles/.worktrees/workflows/.worktrees/shortcuts"
    [ "$output" = "workflows-shortcuts" ]
}

@test "trailing slash is ignored" {
    run cc-session-name "/home/u/Dev/myrepo/.worktrees/add-auth/"
    [ "$output" = "myrepo-add-auth" ]
}

@test "git repo dir -> toplevel basename" {
    local parent repo
    parent="$(mktemp -d)"
    repo="$parent/cleanrepo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    run cc-session-name "$repo"
    [ "$output" = "cleanrepo" ]
    rm -rf "$parent"
}

@test "subdir of a repo collapses to the repo name" {
    local parent repo
    parent="$(mktemp -d)"
    repo="$parent/cleanrepo"
    mkdir -p "$repo/src/deep"
    git -C "$repo" init -q
    run cc-session-name "$repo/src/deep"
    [ "$output" = "cleanrepo" ]
    rm -rf "$parent"
}

@test "subdir of a worktree collapses to <repo>-<slug>" {
    local parent repo
    parent="$(mktemp -d)"
    repo="$parent/cleanrepo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email t@t.test
    git -C "$repo" config user.name tester
    git -C "$repo" commit --allow-empty -q -m init
    git -C "$repo" worktree add -q "$repo/.worktrees/add-auth" -b claude/add-auth
    mkdir -p "$repo/.worktrees/add-auth/src/deep"
    run cc-session-name "$repo/.worktrees/add-auth/src/deep"
    [ "$output" = "cleanrepo-add-auth" ]
    rm -rf "$parent"
}

@test "non-git dir -> basename" {
    local parent dir
    parent="$(mktemp -d)"
    dir="$parent/plain-dir"
    mkdir -p "$dir"
    run cc-session-name "$dir"
    [ "$output" = "plain-dir" ]
    rm -rf "$parent"
}
