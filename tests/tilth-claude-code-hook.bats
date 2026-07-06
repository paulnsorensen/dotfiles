#!/usr/bin/env bats
# Tests for install_tilth_claude_code (.sync-lib.sh) — the post-chezmoi sync
# step that drops the always-current ~/.claude/tilth/inject-cwd.js script via
# `tilth install claude-code` (issue #389: hook wiring itself is
# registry-authored in chezmoi/.chezmoidata/claude.yaml).

load test_helper

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
}

teardown() { teardown_test_env; }

run_install_tilth() {
    PATH="$MOCK_BIN:/usr/bin:/bin" run bash -c "source '$REAL_DOTFILES_DIR/.sync-lib.sh' && install_tilth_claude_code"
}

@test "install_tilth_claude_code invokes tilth install claude-code --edit when tilth is present" {
    export TILTH_CALLS="$TEST_HOME/tilth-calls.log"
    cat > "$MOCK_BIN/tilth" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$TILTH_CALLS"
exit 0
SH
    chmod +x "$MOCK_BIN/tilth"

    run_install_tilth
    assert_success
    assert_file_exists "$TILTH_CALLS"
    grep -qx "install claude-code --edit" "$TILTH_CALLS"
}

@test "install_tilth_claude_code skips and warns when tilth is absent" {
    export TILTH_CALLS="$TEST_HOME/tilth-calls.log"

    run_install_tilth
    assert_success
    assert_output_contains "tilth not installed, skipping claude-code hook wiring"
    [[ ! -f "$TILTH_CALLS" ]]
}
