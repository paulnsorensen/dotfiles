#!/usr/bin/env bats
# Guard: sync_entry must never repoint global home symlinks (~/.zshrc, …) when
# run from a *linked* git worktree. Syncing from an ephemeral Conductor/ccw
# worktree otherwise hijacks the home symlink to a path that dangles the moment
# the worktree is removed, silently breaking the shell (DOTFILES_DIR resolves
# to a dead path → bin/ off PATH). Covers dir_is_linked_worktree + sync_entry.

load test_helper

setup() {
    setup_test_env
    command -v git >/dev/null 2>&1 || skip "git not installed"

    # Primary clone with a tracked home-dotfile source.
    PRIMARY="$TEST_HOME/dotfiles"
    mkdir -p "$PRIMARY"
    echo "export FROM=primary" > "$PRIMARY/zshrc"
    git -C "$PRIMARY" init -q
    git -C "$PRIMARY" -c user.email=t@t -c user.name=t add -A
    git -C "$PRIMARY" -c user.email=t@t -c user.name=t commit -qm init

    # Linked worktree of the same repo (the Conductor/ccw case).
    WORKTREE="$TEST_HOME/wt"
    git -C "$PRIMARY" worktree add --detach -q "$WORKTREE" >/dev/null 2>&1
    echo "export FROM=worktree" > "$WORKTREE/zshrc"

    OLDDIR="$TEST_HOME/bak"
    mkdir -p "$OLDDIR"
    export PRIMARY WORKTREE OLDDIR
}

teardown() { teardown_test_env; }

# Run sync_entry with the sync globals it depends on ($dir, $olddir).
run_sync_entry() {
    local d="$1" file="$2"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh'; dir='$d'; olddir='$OLDDIR'; SYNC_FAILURES=(); sync_entry '$file'"
}

@test "sync_entry creates the home symlink when run from the primary clone" {
    run_sync_entry "$PRIMARY" zshrc
    assert_success
    [[ -L "$TEST_HOME/.zshrc" ]]
    [[ "$(readlink "$TEST_HOME/.zshrc")" == "$PRIMARY/zshrc" ]]
}

@test "sync_entry refuses to create a home symlink from a linked worktree" {
    run_sync_entry "$WORKTREE" zshrc
    assert_success
    [[ ! -e "$TEST_HOME/.zshrc" ]]
    assert_output_contains "linked git worktree"
}

@test "sync_entry from a worktree leaves an existing primary-pointing link intact" {
    ln -s "$PRIMARY/zshrc" "$TEST_HOME/.zshrc"   # the good, primary-pointing link
    run_sync_entry "$WORKTREE" zshrc
    assert_success
    # Not removed, not repointed at the worktree.
    [[ -L "$TEST_HOME/.zshrc" ]]
    [[ "$(readlink "$TEST_HOME/.zshrc")" == "$PRIMARY/zshrc" ]]
}

@test "dir_is_linked_worktree: true for a linked worktree, false for the primary clone" {
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh'; dir_is_linked_worktree '$WORKTREE'"
    assert_success
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh'; dir_is_linked_worktree '$PRIMARY'"
    assert_failure
}

@test "dir_is_linked_worktree: false (fails open) outside any git repo" {
    local nonrepo="$TEST_HOME/plain"
    mkdir -p "$nonrepo"
    run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh'; dir_is_linked_worktree '$nonrepo'"
    assert_failure
}
