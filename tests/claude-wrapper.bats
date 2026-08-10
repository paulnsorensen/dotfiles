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

@test "claude wrapper delegates to the mise shim" {
    run "$REAL_DOTFILES_DIR/bin/claude" --version

    assert_success
    [ "$output" = "mise claude --version" ]
}
