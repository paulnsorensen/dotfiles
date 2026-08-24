#!/usr/bin/env bats
# Tests for install_tilth_claude_code (.sync-lib.sh) — the post-chezmoi sync
# step that registers tilth's edit-mode claude-code integration via
# `tilth install claude-code --edit`. tilth retired the inject-cwd.js
# PreToolUse hook, so the step no longer drops or checks a hook script.

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
    assert_output_contains "tilth not installed, skipping claude-code install"
    [[ ! -f "$TILTH_CALLS" ]]
}

@test "install_tilth_claude_code removes the retired cwd hook before invoking tilth" {
    local retired_hook="$HOME/.claude/tilth/inject-cwd.js"
    mkdir -p "${retired_hook%/*}"
    printf 'retired\n' > "$retired_hook"
    cat > "$MOCK_BIN/tilth" <<'SH'
#!/bin/bash
[[ ! -e "$HOME/.claude/tilth/inject-cwd.js" ]] || exit 70
SH
    chmod +x "$MOCK_BIN/tilth"

    run_install_tilth
    assert_success
    [[ ! -e "$retired_hook" ]]
}

@test "install_tilth_claude_code never mentions the retired inject-cwd.js hook" {
    # tilth retired the inject-cwd.js PreToolUse hook; the install step must
    # not warn about (or expect) the hook script anymore.
    cat > "$MOCK_BIN/tilth" <<'SH'
#!/bin/bash
exit 0
SH
    chmod +x "$MOCK_BIN/tilth"

    run_install_tilth
    assert_success
    assert_output_not_contains "inject-cwd.js"
}
