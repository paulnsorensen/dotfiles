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

# Stub a dotfiles tree wired for `dots upgrade`: `.sync` prints its args and
# runs packages/sync.sh (mirroring the real do_sync path), packages/sync.sh
# prints its UPGRADE_MODE, install-external.sh prints its args. All must be
# invoked — `dots upgrade` now runs a refresh sync, then the skill refresh.
stub_upgrade_dotfiles() {
    local stub_dir="$1"
    mkdir -p "$stub_dir/packages" "$stub_dir/bin" \
             "$stub_dir/chezmoi/lib" "$stub_dir/skills"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    cat > "$stub_dir/.sync" <<'STUB'
#!/bin/bash
echo "stub-dotsync args=$*"
bash "$(dirname "$0")/packages/sync.sh"
STUB
    cat > "$stub_dir/packages/sync.sh" <<'STUB'
#!/bin/bash
echo "stub-sync UPGRADE_MODE=${UPGRADE_MODE:-unset}"
STUB
    cat > "$stub_dir/chezmoi/lib/install-external.sh" <<'STUB'
#!/bin/bash
echo "stub-skill-sync args=$*"
STUB
    : > "$stub_dir/skills/_registry.yaml"
    chmod +x "$stub_dir/.sync" "$stub_dir/packages/sync.sh" \
             "$stub_dir/chezmoi/lib/install-external.sh"
}

@test "dots upgrade runs a refresh sync (UPGRADE_MODE=true), then skill-sync --force" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" upgrade
    assert_success
    assert_output_contains "Upgrading packages"
    # do_sync refresh: forwards the `refresh` arg (force-pulls the vendor cache)
    # and runs packages/sync.sh with UPGRADE_MODE=true.
    assert_output_contains "stub-dotsync args=refresh"
    assert_output_contains "stub-sync UPGRADE_MODE=true"
    assert_output_contains "Refreshing remote skills"
    assert_output_contains "stub-skill-sync args=$stub_dir/skills/_registry.yaml --force"

    # Lock down ordering: the refresh sync (which installs package tools) must
    # run before the npx skill refresh that depends on them.
    local sync_line skill_line
    sync_line=$(printf '%s\n' "$output" | grep -n 'stub-dotsync args=refresh' | head -1 | cut -d: -f1)
    skill_line=$(printf '%s\n' "$output" | grep -n 'stub-skill-sync args=' | head -1 | cut -d: -f1)
    [[ "$sync_line" -lt "$skill_line" ]] || {
        echo "Expected refresh sync before skill refresh; got sync=$sync_line skill=$skill_line" >&2
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
    local stub_dir="$TEST_HOME/update-dotfiles"
    create_mock_repo "$stub_dir"
    mkdir -p "$stub_dir/bin"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"

    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" u 2>&1
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

@test "dots backups command is retired" {
    run dots backups
    assert_failure
    assert_output_contains "Unknown command"
}

@test "dots clean command is retired" {
    run dots clean
    assert_failure
    assert_output_contains "Unknown command"
}

@test "dots rollback points at the git-revert undo path" {
    run dots rollback
    assert_success
    assert_output_contains "git revert"
    assert_output_contains "dots sync"
}

@test "dots sync with no args dispatches to .sync with no extra args" {
    local stub_dir="$TEST_HOME/sync-dotfiles"
    mkdir -p "$stub_dir/bin"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    cat > "$stub_dir/.sync" <<'STUB'
#!/bin/bash
echo "stub-dotsync argc=$# args=[$*]"
STUB
    chmod +x "$stub_dir/.sync"

    DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" sync
    assert_success
    assert_output_contains "stub-dotsync argc=0 args=[]"
}

# Stub a dotfiles tree + a fake chezmoi on PATH for `dots claude diff`.
# The chezmoi stub echoes its args (or the given body) so tests can assert the
# targets/flags and drive the empty/nonzero code paths.
stub_claude_diff() {
    local stub_dir="$1" chezmoi_body="$2"
    mkdir -p "$stub_dir/bin" "$stub_dir/chezmoi" "$TEST_HOME/fake-bin"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    printf '#!/bin/bash\n%s\n' "$chezmoi_body" > "$TEST_HOME/fake-bin/chezmoi"
    chmod +x "$TEST_HOME/fake-bin/chezmoi"
}

@test "dots claude diff invokes chezmoi diff on ~/.claude with the repo source" {
    local stub_dir="$TEST_HOME/claude-diff"
    stub_claude_diff "$stub_dir" 'echo "chezmoi-args=[$*]"'
    DOTFILES_DIR="$stub_dir" PATH="$TEST_HOME/fake-bin:$PATH" run "$stub_dir/bin/dots" claude diff
    assert_success
    assert_output_contains "--source $stub_dir/chezmoi diff $HOME/.claude"
}

@test "dots claude diff prints in-sync message when chezmoi diff is empty" {
    local stub_dir="$TEST_HOME/claude-diff"
    stub_claude_diff "$stub_dir" 'exit 0'  # no output, exit 0 == in sync
    DOTFILES_DIR="$stub_dir" PATH="$TEST_HOME/fake-bin:$PATH" run "$stub_dir/bin/dots" claude diff
    assert_success
    assert_output_contains "in sync with the chezmoi source"
}

@test "dots claude diff propagates a nonzero chezmoi exit" {
    local stub_dir="$TEST_HOME/claude-diff"
    stub_claude_diff "$stub_dir" 'exit 3'
    DOTFILES_DIR="$stub_dir" PATH="$TEST_HOME/fake-bin:$PATH" run "$stub_dir/bin/dots" claude diff
    [[ "$status" -eq 3 ]]
    assert_output_contains "chezmoi diff failed (exit 3)"
}

# Plant a modify_settings.json gate + a live settings.json so `dots claude diff`
# runs the halt gate. $2 is the gate script body (controls its exit code).
stub_claude_gate() {
    local stub_dir="$1" gate_body="$2"
    mkdir -p "$stub_dir/chezmoi/dot_claude" "$HOME/.claude"
    printf '#!/bin/sh\n%s\n' "$gate_body" \
        > "$stub_dir/chezmoi/dot_claude/modify_settings.json"
    echo '{}' > "$HOME/.claude/settings.json"
}

@test "dots claude diff surfaces a would-be halt the diff itself cannot see" {
    local stub_dir="$TEST_HOME/claude-diff"
    stub_claude_diff "$stub_dir" 'exit 0'  # chezmoi diff reports "in sync"
    stub_claude_gate "$stub_dir" 'echo "unknown key: env.SSL_CERT_FILE" >&2; exit 1'
    DOTFILES_DIR="$stub_dir" PATH="$TEST_HOME/fake-bin:$PATH" run "$stub_dir/bin/dots" claude diff
    assert_failure
    assert_output_contains "would HALT the next sync"
    assert_output_contains "unknown key: env.SSL_CERT_FILE"
}

@test "dots claude diff passes the gate then reports in-sync" {
    local stub_dir="$TEST_HOME/claude-diff"
    stub_claude_diff "$stub_dir" 'exit 0'
    stub_claude_gate "$stub_dir" 'cat >/dev/null; exit 0'  # gate OK
    DOTFILES_DIR="$stub_dir" PATH="$TEST_HOME/fake-bin:$PATH" run "$stub_dir/bin/dots" claude diff
    assert_success
    assert_output_contains "in sync with the chezmoi source"
}

@test "dots claude with an unknown action fails with usage" {
    run dots claude bogus
    assert_failure
    assert_output_contains "Usage: dots claude diff"
}

@test "dots claude help mentions ~/.claude.json MCP drift is not covered" {
    run dots help
    assert_success
    assert_output_contains "claude diff"
    assert_output_contains ".claude.json"
}
