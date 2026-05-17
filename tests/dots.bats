#!/usr/bin/env bats
# Tests for the dots command

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
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

# Stub a dotfiles tree wired for `dots upgrade`: packages/sync.sh prints its
# UPGRADE_MODE, install-external.sh prints its args. Both must be invoked.
stub_upgrade_dotfiles() {
    local stub_dir="$1"
    mkdir -p "$stub_dir/packages" "$stub_dir/bin" \
             "$stub_dir/chezmoi/lib" "$stub_dir/skills"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    cat > "$stub_dir/packages/sync.sh" <<'STUB'
#!/bin/bash
echo "stub-sync UPGRADE_MODE=${UPGRADE_MODE:-unset}"
STUB
    cat > "$stub_dir/chezmoi/lib/install-external.sh" <<'STUB'
#!/bin/bash
echo "stub-skill-sync args=$*"
STUB
    : > "$stub_dir/skills/_registry.yaml"
    chmod +x "$stub_dir/packages/sync.sh" \
             "$stub_dir/chezmoi/lib/install-external.sh"
}

@test "dots upgrade runs packages/sync.sh with UPGRADE_MODE=true, then skill-sync --force" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" upgrade
    assert_success
    assert_output_contains "Upgrading packages"
    assert_output_contains "stub-sync UPGRADE_MODE=true"
    assert_output_contains "Refreshing remote skills"
    assert_output_contains "stub-skill-sync args=$stub_dir/skills/_registry.yaml --force"

    # Lock down ordering: package sync must run before skill refresh.
    local pkg_line skill_line
    pkg_line=$(printf '%s\n' "$output" | grep -n 'stub-sync UPGRADE_MODE=true' | head -1 | cut -d: -f1)
    skill_line=$(printf '%s\n' "$output" | grep -n 'stub-skill-sync args=' | head -1 | cut -d: -f1)
    [[ "$pkg_line" -lt "$skill_line" ]] || {
        echo "Expected package sync before skill refresh; got pkg=$pkg_line skill=$skill_line" >&2
        return 1
    }
}

@test "dots up shorthand routes to upgrade (packages + skill refresh)" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" up
    assert_success
    assert_output_contains "stub-sync UPGRADE_MODE=true"
    assert_output_contains "stub-skill-sync args=$stub_dir/skills/_registry.yaml --force"
}

@test "dots upgrade keeps going when skill-sync fails (warns but exits 0)" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    # Replace skill-sync stub with a failing one
    cat > "$stub_dir/chezmoi/lib/install-external.sh" <<'STUB'
#!/bin/bash
echo "stub-skill-sync FAILING" >&2
exit 1
STUB
    chmod +x "$stub_dir/chezmoi/lib/install-external.sh"

    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" upgrade
    assert_success  # package upgrade is the primary action; skill failure shouldn't abort
    assert_output_contains "stub-sync UPGRADE_MODE=true"
    assert_output_contains "Remote skills refresh failed"
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
    run dots u 2>&1
    assert_success
    assert_output_contains "Updating"
}

@test "dots sync shorthand works" {
    run dots s --help 2>&1
    [[ "$output" != *"Unknown command"* ]]
    assert_output_contains "Usage"
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
