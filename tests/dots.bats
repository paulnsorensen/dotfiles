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

# Stub a dotfiles tree wired for `dots upgrade`: git and .sync record their
# invocations so the pull-before-sync order and upgrade scope are observable.
stub_upgrade_dotfiles() {
    local stub_dir="$1"
    mkdir -p "$stub_dir/packages" "$stub_dir/bin" "$stub_dir/chezmoi/lib" "$stub_dir/skills"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    : > "$stub_dir/skills/_registry.yaml"
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
echo "stub-skill-sync args=[$*] exclude=${SKILL_EXCLUDE_AGENTS:-unset}"
STUB
    cat > "$stub_dir/bin/git" <<'STUB'
#!/bin/bash
echo "stub-git $*"
if [[ "$1" == "pull" && "${GIT_PULL_FAIL:-false}" == "true" ]]; then
    exit 1
fi
STUB
    chmod +x "$stub_dir/.sync" "$stub_dir/packages/sync.sh" "$stub_dir/chezmoi/lib/install-external.sh" "$stub_dir/bin/git"
}

@test "dots upgrade pulls before an upgrade sync and refreshes remote skills" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    PATH="$stub_dir/bin:$PATH" DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" upgrade
    assert_success
    assert_output_contains "stub-git pull --rebase"
    assert_output_contains "stub-dotsync args="
    assert_output_contains "stub-sync UPGRADE_MODE=true"
    assert_output_contains "stub-skill-sync args=[$stub_dir/skills/_registry.yaml --force] exclude=claude-code"
    assert_output_not_contains "args=refresh"

    local pull_line sync_line
    pull_line=$(printf '%s\n' "$output" | grep -n 'stub-git pull --rebase' | head -1 | cut -d: -f1)
    sync_line=$(printf '%s\n' "$output" | grep -n 'stub-dotsync args=' | head -1 | cut -d: -f1)
    [[ "$pull_line" -lt "$sync_line" ]] || {
        echo "Expected git pull before upgrade sync; got pull=$pull_line sync=$sync_line" >&2
        return 1
    }
}

@test "dots up shorthand uses the same pull, sync, and skill-refresh flow" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    PATH="$stub_dir/bin:$PATH" DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" up
    assert_success
    assert_output_contains "stub-git pull --rebase"
    assert_output_contains "stub-sync UPGRADE_MODE=true"
    assert_output_contains "stub-skill-sync args=[$stub_dir/skills/_registry.yaml --force] exclude=claude-code"
    assert_output_not_contains "args=refresh"
}

@test "dots upgrade stops before sync when git pull fails" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    GIT_PULL_FAIL=true PATH="$stub_dir/bin:$PATH" DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" upgrade
    assert_failure
    assert_output_contains "stub-git pull --rebase"
    assert_output_not_contains "stub-dotsync"
}

@test "dots sync refreshes non-Claude skills" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    PATH="$stub_dir/bin:$PATH" DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" sync
    assert_success
    assert_output_contains "stub-skill-sync args=[$stub_dir/skills/_registry.yaml --force] exclude=claude-code"
}

@test "dots sync preserves caller skill exclusions" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    SKILL_EXCLUDE_AGENTS=cursor PATH="$stub_dir/bin:$PATH" DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" sync
    assert_success
    assert_output_contains "exclude=cursor claude-code"
}

@test "dots sync --dry-run skips the skill refresh" {
    local stub_dir="$TEST_HOME/stub-dotfiles"
    stub_upgrade_dotfiles "$stub_dir"
    PATH="$stub_dir/bin:$PATH" DOTFILES_DIR="$stub_dir" run "$stub_dir/bin/dots" sync --dry-run
    assert_success
    assert_output_not_contains "stub-skill-sync"
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

stub_broker_install_root() {
    local root="$1"
    mkdir -p "$root"
    cp "$DOTFILES_DIR/bin/agent-secret-broker" "$root/agent-secret-broker"
    cp "$DOTFILES_DIR/bin/agent-secret-proxy" "$root/agent-secret-proxy"
    cp "$DOTFILES_DIR/bin/agent-secretctl" "$root/agent-secretctl"
    cp "$DOTFILES_DIR/bin/lib/agent-secret-python.sh" "$root/agent-secret-python.sh"
    cp "$DOTFILES_DIR/scripts/agent-secret-broker.py" "$root/agent-secret-broker.py"
}

@test "dots doctor reports stale installed broker assets" {
    local root="$TEST_HOME/agent-secret-libexec" fake_bin="$TEST_HOME/fake-bin"
    stub_broker_install_root "$root"
    mkdir -p "$fake_bin"
    printf '#!/bin/sh\nexit 0\n' > "$fake_bin/chezmoi"
    printf '#!/bin/sh\nexit 0\n' > "$fake_bin/prek"
    chmod +x "$fake_bin/chezmoi" "$fake_bin/prek"

    PATH="$fake_bin:$PATH" AGENT_SECRET_INSTALL_ROOT="$root" run dots doctor
    assert_success
    assert_output_contains "Broker assets match the source"
    local baseline_issues
    baseline_issues=$(printf '%s\n' "$output" | grep -oE 'Found [0-9]+' | grep -oE '[0-9]+' || true)
    baseline_issues="${baseline_issues:-0}"

    printf '\n# stale fixture\n' >> "$root/agent-secret-broker.py"

    PATH="$fake_bin:$PATH" AGENT_SECRET_INSTALL_ROOT="$root" run dots doctor
    assert_success
    assert_output_contains "Broker assets: stale"
    assert_output_contains "agent-secret-broker.py"
    local stale_issues
    stale_issues=$(printf '%s\n' "$output" | grep -oE 'Found [0-9]+' | grep -oE '[0-9]+' || true)
    stale_issues="${stale_issues:-0}"

    [[ "$stale_issues" -eq $((baseline_issues + 1)) ]] || {
        echo "Expected stale-broker issue count to be baseline+1 (baseline=$baseline_issues, stale=$stale_issues)" >&2
        return 1
    }
}

@test "dots sync warns when installed broker assets are stale" {
    local stub_dir="$TEST_HOME/stale-sync-dotfiles" root="$TEST_HOME/agent-secret-libexec"
    mkdir -p "$stub_dir/bin/lib" "$stub_dir/scripts" "$stub_dir/chezmoi/lib" "$stub_dir/skills"
    cp "$DOTFILES_DIR/bin/lib/agent-secret-staleness.sh" "$stub_dir/bin/lib/agent-secret-staleness.sh"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    cp "$DOTFILES_DIR/bin/lib/agent-secret-assets.sh" "$stub_dir/bin/lib/agent-secret-assets.sh"
    cp "$DOTFILES_DIR/bin/agent-secret-broker" "$stub_dir/bin/agent-secret-broker"
    cp "$DOTFILES_DIR/bin/agent-secret-proxy" "$stub_dir/bin/agent-secret-proxy"
    cp "$DOTFILES_DIR/bin/agent-secretctl" "$stub_dir/bin/agent-secretctl"
    cp "$DOTFILES_DIR/bin/lib/agent-secret-python.sh" "$stub_dir/bin/lib/agent-secret-python.sh"
    cp "$DOTFILES_DIR/scripts/agent-secret-broker.py" "$stub_dir/scripts/agent-secret-broker.py"
    printf '#!/bin/sh\nexit 0\n' > "$stub_dir/.sync"
    printf '#!/bin/sh\nexit 0\n' > "$stub_dir/chezmoi/lib/install-external.sh"
    chmod +x "$stub_dir/.sync" "$stub_dir/chezmoi/lib/install-external.sh"
    stub_broker_install_root "$root"
    printf '\n# stale fixture\n' >> "$root/agent-secret-broker.py"

    DOTFILES_DIR="$stub_dir" AGENT_SECRET_INSTALL_ROOT="$root" run "$stub_dir/bin/dots" sync

    assert_success
    assert_output_contains "agent-secret broker deployment is stale"
    assert_output_contains "bin/vault-provision"
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

# Stub a real git origin + clone wired for `dots update`: the clone tracks
# origin, and a second commit lands on origin after cloning so `dots update`
# has something to pull before it runs `do_sync` (and the broker check within).
stub_update_dotfiles() {
    local origin_dir="$1" stub_dir="$2"
    mkdir -p "$origin_dir/bin/lib" "$origin_dir/chezmoi/lib" "$origin_dir/skills" "$origin_dir/scripts"
    cp "$DOTFILES_DIR/bin/dots" "$origin_dir/bin/dots"
    cp "$DOTFILES_DIR/bin/lib/agent-secret-staleness.sh" "$origin_dir/bin/lib/agent-secret-staleness.sh"
    cp "$DOTFILES_DIR/bin/lib/agent-secret-assets.sh" "$origin_dir/bin/lib/agent-secret-assets.sh"
    cp "$DOTFILES_DIR/bin/agent-secret-broker" "$origin_dir/bin/agent-secret-broker"
    cp "$DOTFILES_DIR/bin/agent-secret-proxy" "$origin_dir/bin/agent-secret-proxy"
    cp "$DOTFILES_DIR/bin/agent-secretctl" "$origin_dir/bin/agent-secretctl"
    cp "$DOTFILES_DIR/bin/lib/agent-secret-python.sh" "$origin_dir/bin/lib/agent-secret-python.sh"
    cp "$DOTFILES_DIR/scripts/agent-secret-broker.py" "$origin_dir/scripts/agent-secret-broker.py"
    : > "$origin_dir/skills/_registry.yaml"
    printf '#!/bin/bash\nexit 0\n' > "$origin_dir/chezmoi/lib/install-external.sh"
    printf '#!/bin/bash\necho "stub-dotsync args=$*"\n' > "$origin_dir/.sync"
    chmod +x "$origin_dir/chezmoi/lib/install-external.sh" "$origin_dir/.sync"
    (
        cd "$origin_dir" || exit 1
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        git add -A
        git commit -m "Initial commit" --quiet
    )
    git clone --quiet "$origin_dir" "$stub_dir"
    (
        cd "$origin_dir" || exit 1
        printf '#!/bin/bash\necho "stub-dotsync args=$*"\n# second commit\n' > .sync
        git add -A
        git commit -m "Second commit" --quiet
    )
}

@test "dots update runs the broker staleness check after pulling" {
    local origin_dir="$TEST_HOME/update-origin" stub_dir="$TEST_HOME/update-dotfiles"
    local root="$TEST_HOME/agent-secret-libexec"
    stub_update_dotfiles "$origin_dir" "$stub_dir"
    stub_broker_install_root "$root"
    printf '\n# stale fixture\n' >> "$root/agent-secret-broker.py"

    DOTFILES_DIR="$stub_dir" AGENT_SECRET_INSTALL_ROOT="$root" run "$stub_dir/bin/dots" update

    assert_success
    assert_output_contains "stub-dotsync args="
    assert_output_contains "agent-secret broker deployment is stale"
    assert_output_contains "bin/vault-provision"
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
    mkdir -p "$stub_dir/bin" "$stub_dir/chezmoi/lib" "$stub_dir/skills"
    cp "$DOTFILES_DIR/bin/dots" "$stub_dir/bin/dots"
    : > "$stub_dir/skills/_registry.yaml"
    cat > "$stub_dir/.sync" <<'STUB'
#!/bin/bash
echo "stub-dotsync argc=$# args=[$*]"
STUB
    cat > "$stub_dir/chezmoi/lib/install-external.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x "$stub_dir/.sync" "$stub_dir/chezmoi/lib/install-external.sh"

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
