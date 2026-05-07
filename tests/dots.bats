#!/usr/bin/env bats
# Tests for the dots command

load test_helper

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    export DOTS_TEST_LOG="$TEST_HOME/dots-sync.log"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

create_mock_sync_dotfiles() {
    export FAKE_DOTFILES="$TEST_HOME/mock-dotfiles"
    mkdir -p "$FAKE_DOTFILES/packages"

    cat > "$FAKE_DOTFILES/packages/sync.sh" << 'SCRIPT'
#!/bin/bash
printf 'packages DOTFILES_DEV=%s QUICK_SYNC=%s FORCE_PACKAGES=%s\n' \
  "${DOTFILES_DEV:-unset}" "${QUICK_SYNC:-unset}" "${FORCE_PACKAGES:-unset}" >> "$DOTS_TEST_LOG"
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    cat > "$FAKE_DOTFILES/.sync-with-rollback" << 'SCRIPT'
#!/bin/bash
printf 'legacy %s DOTFILES_DEV=%s QUICK_SYNC=%s FORCE_PACKAGES=%s\n' \
  "$*" "${DOTFILES_DEV:-unset}" "${QUICK_SYNC:-unset}" "${FORCE_PACKAGES:-unset}" >> "$DOTS_TEST_LOG"
SCRIPT
    chmod +x "$FAKE_DOTFILES/.sync-with-rollback"
}

install_mock_chezmoi() {
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    cat > "$MOCK_BIN/chezmoi" << 'SCRIPT'
#!/bin/bash
printf 'chezmoi %s\n' "$*" >> "$DOTS_TEST_LOG"
SCRIPT
    chmod +x "$MOCK_BIN/chezmoi"
}

@test "dots command exists and is executable" {
    [[ -x "$DOTFILES_DIR/bin/dots" ]]
}

@test "dots help displays usage information" {
    run dots help
    assert_success
    assert_output_contains "Usage: dots [command] [args]"
    assert_output_contains "update"
    assert_output_contains "sync"
    assert_output_contains "upgrade"
    assert_output_contains "rollback"
}

@test "dots upgrade dispatches to packages/sync.sh with UPGRADE_MODE=true" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    mkdir -p "$stub_dir/packages" "$stub_dir/bin"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    cat > "$stub_dir/packages/sync.sh" <<'STUB'
#!/bin/bash
echo "stub-sync UPGRADE_MODE=${UPGRADE_MODE:-unset}"
STUB
    chmod +x "$stub_dir/packages/sync.sh"
    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" upgrade
    assert_success
    assert_output_contains "Upgrading packages"
    assert_output_contains "stub-sync UPGRADE_MODE=true"
}

@test "dots up shorthand routes to upgrade" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    mkdir -p "$stub_dir/packages" "$stub_dir/bin"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    cat > "$stub_dir/packages/sync.sh" <<'STUB'
#!/bin/bash
echo "stub-sync UPGRADE_MODE=${UPGRADE_MODE:-unset}"
STUB
    chmod +x "$stub_dir/packages/sync.sh"
    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" up
    assert_success
    assert_output_contains "stub-sync UPGRADE_MODE=true"
}

@test "dots with no arguments shows status" {
    # Don't try to create repo in actual dotfiles dir - it already exists
    # Just run the command
    run dots
    assert_success
    assert_output_contains "Dotfiles Status"
}

@test "dots accepts shorthand commands" {
    run dots h
    assert_success
    assert_output_contains "Usage: dots"
}

@test "dots doctor performs health checks and profiling" {
    run dots doctor
    assert_success
    assert_output_contains "Dotfiles Health Check"
    assert_output_contains "Checking symlinks"
    assert_output_contains "Checking dependencies"
    assert_output_contains "Profiling shell startup"
}

@test "dots handles unknown commands gracefully" {
    run dots nonexistent
    assert_failure
    assert_output_contains "Unknown command"
}

@test "dots update shorthand works" {
    local fake_update_dir="$TEST_HOME/update-dotfiles"
    mkdir -p "$fake_update_dir"
    cat > "$MOCK_BIN/git" << 'SCRIPT'
#!/bin/bash
case "$1" in
    fetch) exit 0 ;;
    rev-parse) echo "abc123" ;;
    merge-base) echo "abc123" ;;
    *) exit 0 ;;
esac
SCRIPT
    chmod +x "$MOCK_BIN/git"

    run env DOTFILES_DIR="$fake_update_dir" PATH="$MOCK_BIN:$PATH" dots u 2>&1
    assert_success
    assert_output_contains "Updating"
    assert_output_contains "Already up to date"
}

@test "dots sync shorthand works" {
    run dots s --help 2>&1
    [[ "$output" != *"Unknown command"* ]]
    assert_output_contains "Usage"
}

@test "dots sync runs packages then legacy sync then chezmoi" {
    create_mock_sync_dotfiles
    install_mock_chezmoi

    run env DOTFILES_DIR="$FAKE_DOTFILES" DOTS_TEST_LOG="$DOTS_TEST_LOG" PATH="$MOCK_BIN:$PATH" \
        dots sync dev q refresh
    assert_success

    assert_file_exists "$DOTS_TEST_LOG"
    run cat "$DOTS_TEST_LOG"
    assert_success
    assert_output_contains "packages DOTFILES_DEV=true QUICK_SYNC=true FORCE_PACKAGES=true"
    assert_output_contains "legacy no-packages dev q refresh DOTFILES_DEV=true QUICK_SYNC=true FORCE_PACKAGES=true"
    assert_output_contains "chezmoi apply"

    local packages_line legacy_line chezmoi_line
    packages_line=$(grep -n '^packages ' "$DOTS_TEST_LOG" | cut -d: -f1)
    legacy_line=$(grep -n '^legacy ' "$DOTS_TEST_LOG" | cut -d: -f1)
    chezmoi_line=$(grep -n '^chezmoi ' "$DOTS_TEST_LOG" | cut -d: -f1)
    [[ "$packages_line" -lt "$legacy_line" ]]
    [[ "$legacy_line" -lt "$chezmoi_line" ]]
}

@test "dots sync preserves quick sync for packages and legacy args" {
    create_mock_sync_dotfiles

    run env DOTFILES_DIR="$FAKE_DOTFILES" DOTS_TEST_LOG="$DOTS_TEST_LOG" PATH="$MOCK_BIN:$PATH" \
        dots sync q
    assert_success

    run cat "$DOTS_TEST_LOG"
    assert_success
    assert_output_contains "packages DOTFILES_DEV=false QUICK_SYNC=true FORCE_PACKAGES=unset"
    assert_output_contains "legacy no-packages q DOTFILES_DEV=false QUICK_SYNC=true FORCE_PACKAGES=unset"
}

@test "dots packages command runs package sync only" {
    create_mock_sync_dotfiles

    run env DOTFILES_DIR="$FAKE_DOTFILES" DOTS_TEST_LOG="$DOTS_TEST_LOG" PATH="$MOCK_BIN:$PATH" \
        dots packages refresh
    assert_success

    run cat "$DOTS_TEST_LOG"
    assert_success
    assert_output_contains "packages DOTFILES_DEV=false QUICK_SYNC=false FORCE_PACKAGES=true"
    [[ "$output" != *"legacy"* ]]
}

@test "dots p shorthand runs package sync only" {
    create_mock_sync_dotfiles

    run env DOTFILES_DIR="$FAKE_DOTFILES" DOTS_TEST_LOG="$DOTS_TEST_LOG" PATH="$MOCK_BIN:$PATH" \
        dots p dev
    assert_success

    run cat "$DOTS_TEST_LOG"
    assert_success
    assert_output_contains "packages DOTFILES_DEV=true QUICK_SYNC=false FORCE_PACKAGES=unset"
    [[ "$output" != *"legacy"* ]]
}

@test "dots sync refresh round-trips FORCE_PACKAGES and still invokes chezmoi apply" {
    # Focused regression: refresh alone (no dev/q) must reach the packages
    # stage with FORCE_PACKAGES=true AND still trigger chezmoi apply at the
    # tail of the chain. The existing `dots sync runs packages then legacy
    # sync then chezmoi` test combines refresh with dev+q, masking whether
    # refresh-only would round-trip correctly.
    create_mock_sync_dotfiles
    install_mock_chezmoi

    run env DOTFILES_DIR="$FAKE_DOTFILES" DOTS_TEST_LOG="$DOTS_TEST_LOG" PATH="$MOCK_BIN:$PATH" \
        dots sync refresh
    assert_success

    run cat "$DOTS_TEST_LOG"
    assert_success
    assert_output_contains "packages DOTFILES_DEV=false QUICK_SYNC=false FORCE_PACKAGES=true"
    assert_output_contains "legacy no-packages refresh DOTFILES_DEV=false QUICK_SYNC=false FORCE_PACKAGES=true"
    assert_output_contains "chezmoi apply"
}

@test "dots sync skips chezmoi apply with warning when chezmoi/ source is missing" {
    # do_chezmoi_apply short-circuits when $DOTFILES_DIR/chezmoi/ is absent.
    # Build a minimal fake DOTFILES_DIR with packages/ but no chezmoi/ subdir.
    # NOTE: don't call install_mock_chezmoi — that helper creates the chezmoi/
    # source dir as a side effect, which would defeat the test premise.
    export FAKE_DOTFILES="$TEST_HOME/no-chezmoi-dotfiles"
    mkdir -p "$FAKE_DOTFILES/packages"

    cat > "$FAKE_DOTFILES/packages/sync.sh" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
    chmod +x "$FAKE_DOTFILES/packages/sync.sh"

    cat > "$FAKE_DOTFILES/.sync-with-rollback" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
    chmod +x "$FAKE_DOTFILES/.sync-with-rollback"

    # Install just the chezmoi binary mock (without the source-dir side effect).
    cat > "$MOCK_BIN/chezmoi" <<SCRIPT
#!/bin/bash
printf 'chezmoi %s\n' "\$*" >> "$DOTS_TEST_LOG"
SCRIPT
    chmod +x "$MOCK_BIN/chezmoi"

    run env DOTFILES_DIR="$FAKE_DOTFILES" DOTS_TEST_LOG="$DOTS_TEST_LOG" PATH="$MOCK_BIN:$PATH" \
        dots sync
    assert_success
    assert_output_contains "chezmoi source not found, skipping apply"

    # Negative assertion: chezmoi binary was never invoked.
    if [[ -f "$DOTS_TEST_LOG" ]]; then
        run cat "$DOTS_TEST_LOG"
        if [[ "$output" == *"chezmoi"* ]]; then
            echo "chezmoi was invoked despite missing source dir" >&2
            return 1
        fi
    fi
}

@test "dots sync skips chezmoi apply with warning when chezmoi binary is missing" {
    # do_chezmoi_apply checks chezmoi/ source first, then `command -v chezmoi`.
    # To exercise the second branch the source dir must exist; the binary
    # must not be on PATH.
    create_mock_sync_dotfiles
    mkdir -p "$FAKE_DOTFILES/chezmoi"
    # Deliberately do NOT install_mock_chezmoi — leave the binary missing.

    run env DOTFILES_DIR="$FAKE_DOTFILES" DOTS_TEST_LOG="$DOTS_TEST_LOG" \
        PATH="$REAL_DOTFILES_DIR/bin:$MOCK_BIN:/usr/bin:/bin" \
        dots sync
    assert_success
    assert_output_contains "chezmoi not installed, skipping apply"
}

@test "dots test shorthand works" {
    run dots t --help
    assert_success
}

@test "dots backups command runs" {
    run dots backups
    # Exits 0 with backup list, or 1 if no backups dir exists
    [[ "$output" == *"backup"* || "$output" == *"Backup"* ]]
    [[ "$output" != *"Unknown command"* ]]
}

@test "dots rollback without args shows help" {
    run dots rollback
    assert_failure
    assert_output_contains "backup"
}
