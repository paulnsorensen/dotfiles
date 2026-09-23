#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export DOTFILES_DIR="$TEST_HOME/dotfiles"
    git init -q -b main "$TEST_HOME/seed"
    git -C "$TEST_HOME/seed" config user.email test@example.com
    git -C "$TEST_HOME/seed" config user.name Test
    printf 'initial\n' > "$TEST_HOME/seed/tracked"
    git -C "$TEST_HOME/seed" add tracked
    git -C "$TEST_HOME/seed" commit -qm initial
    git clone -q --bare "$TEST_HOME/seed" "$TEST_HOME/remote.git"
    git clone -q "$TEST_HOME/remote.git" "$DOTFILES_DIR"
    mkdir -p "$DOTFILES_DIR/bin" "$TEST_HOME/elsewhere"
    printf 'bin/\n' >> "$DOTFILES_DIR/.git/info/exclude"
    cat > "$DOTFILES_DIR/bin/dots" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_HOME/calls"
if [ "${DIRTY_SYNC:-}" = 1 ]; then
    printf 'dirty\n' > "$DOTFILES_DIR/sync-change"
fi
STUB
    chmod +x "$DOTFILES_DIR/bin/dots"
}

teardown() {
    teardown_test_env
}

run_dps() {
    cd "$TEST_HOME/elsewhere" || return 1
    run zsh -fc 'source "$REAL_DOTFILES_DIR/zsh/dots-update.zsh"; dps'
}

@test "dps pulls and syncs from another directory" {
    printf 'new\n' > "$TEST_HOME/seed/tracked"
    git -C "$TEST_HOME/seed" commit -qam update
    git -C "$TEST_HOME/seed" push -q "$TEST_HOME/remote.git" main

    run_dps

    assert_success
    [ "$(cat "$DOTFILES_DIR/tracked")" = new ]
    [ "$(cat "$TEST_HOME/calls")" = sync ]
    [ -z "$(git -C "$DOTFILES_DIR" status --porcelain)" ]
}

@test "dps stops before pull and sync when dotfiles is dirty" {
    printf 'local\n' > "$DOTFILES_DIR/untracked"

    run_dps

    assert_failure
    assert_output_contains "uncommitted changes"
    [ ! -e "$TEST_HOME/calls" ]
}

@test "dps reports changes made by sync" {
    DIRTY_SYNC=1 run_dps

    assert_failure
    assert_output_contains "after sync"
    [ "$(cat "$TEST_HOME/calls")" = sync ]
}
