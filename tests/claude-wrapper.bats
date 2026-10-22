#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    # The guard reads live machine state — pgrep -cx claude and /proc/meminfo —
    # so leaving it armed makes this fail whenever the host happens to sit at the
    # 8-session ceiling or under 15% free RAM. Delegation is what's under test, so
    # disarm the guard rather than depend on ambient load.
    export CLAUDE_GUARD=0
    export XDG_DATA_HOME="$TEST_HOME/.local/share"
    mkdir -p "$XDG_DATA_HOME/mise/shims"
    cat > "$XDG_DATA_HOME/mise/shims/claude" <<'SH'
#!/bin/sh
echo "mise claude $*"
SH
    chmod +x "$XDG_DATA_HOME/mise/shims/claude"
}

teardown() {
    teardown_test_env
}

# stub_pgrep <count> — fake `pgrep -cx claude` and arm the guard.
stub_pgrep() {
    [[ -r /proc/meminfo ]] || skip "the guard runs only with /proc/meminfo"
    # The RAM block runs first; below 15% free it hides the session checks.
    local avail_kb total_kb
    avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    (( avail_kb * 100 / total_kb >= 15 )) || skip "the session checks need at least 15% free RAM"
    mkdir -p "$TEST_HOME/stub-bin"
    printf '#!/bin/sh\necho %s\n' "$1" > "$TEST_HOME/stub-bin/pgrep"
    chmod +x "$TEST_HOME/stub-bin/pgrep"
    export PATH="$TEST_HOME/stub-bin:$PATH" CLAUDE_GUARD=1
}

@test "the guard lets a session start below the ceiling of 14" {
    stub_pgrep 13
    run "$REAL_DOTFILES_DIR/bin/claude" --version
    assert_success
    assert_output_contains "mise claude --version"
}

@test "the guard blocks a session at the ceiling of 14" {
    stub_pgrep 14
    run "$REAL_DOTFILES_DIR/bin/claude" --version
    assert_failure
    assert_output_contains "ceiling 14"
}

@test "the guard warns from 10 sessions" {
    stub_pgrep 9
    run "$REAL_DOTFILES_DIR/bin/claude" --version
    assert_success
    assert_output_contains "mise claude --version"
    assert_output_not_contains "warning"
    stub_pgrep 10
    run "$REAL_DOTFILES_DIR/bin/claude" --version
    assert_success
    assert_output_contains "mise claude --version"
    assert_output_contains "warning"
}

@test "claude wrapper delegates to the mise shim" {
    run "$REAL_DOTFILES_DIR/bin/claude" --version

    assert_success
    [ "$output" = "mise claude --version" ]
}
