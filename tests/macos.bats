#!/usr/bin/env bats
# shellcheck disable=SC2016  # Mock scripts expand variables when they run.
load test_helper

SYNC_SCRIPT="$REAL_DOTFILES_DIR/macos/.sync"

setup() {
    setup_test_env
    [[ "$(uname -s)" == "Darwin" ]] || skip "macOS defaults/plutil required"

    export MOCK_BIN="$TEST_HOME/bin"
    export HOTKEY_DOMAIN="$TEST_HOME/com.apple.symbolichotkeys"
    export COMMAND_LOG="$TEST_HOME/commands.log"
    export LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
    mkdir -p "$MOCK_BIN"

    /usr/bin/plutil -create xml1 "$HOTKEY_DOMAIN.plist"
    /usr/bin/plutil -insert AppleSymbolicHotKeys -json '{
      "60": {"enabled": true, "value": {"parameters": [32, 49, 262144], "type": "standard"}},
      "61": {"enabled": true, "value": {"parameters": [32, 49, 786432], "type": "standard"}}
    }' "$HOTKEY_DOMAIN.plist"

    cat > "$MOCK_BIN/defaults" <<'MOCK'
#!/bin/bash
command="$1"
domain="$2"
printf '%s\n' "$*" >> "$COMMAND_LOG"
if [[ "$command" == "export" || "$command" == "import" ]]; then
    shift 2
    exec /usr/bin/defaults "$command" "$HOTKEY_DOMAIN" "$@"
fi
exit 0
MOCK
    cat > "$MOCK_BIN/launchctl" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
exit 0
MOCK
    printf '#!/bin/bash\nprintf "Darwin\\n"\n' > "$MOCK_BIN/uname"
    chmod +x "$MOCK_BIN/defaults" "$MOCK_BIN/launchctl" "$MOCK_BIN/uname"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() { teardown_test_env; }

@test "macos sync writes typed symbolic-hotkey values and preserves input-source bindings" {
    run bash "$SYNC_SCRIPT"
    assert_success

    local prefs="$HOTKEY_DOMAIN.plist"
    run /usr/bin/plutil -extract AppleSymbolicHotKeys.60.enabled raw -expect bool "$prefs"
    assert_success
    [ "$output" = "false" ]
    run /usr/bin/plutil -extract AppleSymbolicHotKeys.61.enabled raw -expect bool "$prefs"
    assert_success
    [ "$output" = "false" ]
    run /usr/bin/plutil -extract AppleSymbolicHotKeys.60.value.parameters.2 raw -expect integer "$prefs"
    assert_success
    [ "$output" = "262144" ]
    run /usr/bin/plutil -extract AppleSymbolicHotKeys.61.value.parameters.2 raw -expect integer "$prefs"
    assert_success
    [ "$output" = "786432" ]
    run /usr/bin/plutil -extract AppleSymbolicHotKeys.160.enabled raw -expect bool "$prefs"
    assert_success
    [ "$output" = "true" ]
    for index in 0 1 2; do
        run /usr/bin/plutil -extract "AppleSymbolicHotKeys.160.value.parameters.$index" raw -expect integer "$prefs"
        assert_success
    done
    [ "$( /usr/bin/plutil -extract AppleSymbolicHotKeys.160.value.parameters.0 raw -expect integer "$prefs" )" = "32" ]
    [ "$( /usr/bin/plutil -extract AppleSymbolicHotKeys.160.value.parameters.1 raw -expect integer "$prefs" )" = "49" ]
    [ "$( /usr/bin/plutil -extract AppleSymbolicHotKeys.160.value.parameters.2 raw -expect integer "$prefs" )" = "1179648" ]
    run /usr/bin/plutil -extract AppleSymbolicHotKeys.160.value.type raw -expect string "$prefs"
    assert_success
    [ "$output" = "standard" ]
}

@test "macos sync installs and bootstraps the Caps Lock to Control LaunchAgent" {
    run bash "$SYNC_SCRIPT"
    assert_success

    local plist="$REAL_DOTFILES_DIR/macos/com.local.KeyRemapping.plist"
    local target="$HOME/Library/LaunchAgents/com.local.KeyRemapping.plist"
    assert_symlink "$target" "$plist"

    for index in 0 1 2; do
        run /usr/bin/plutil -extract "ProgramArguments.$index" raw -expect string "$plist"
        assert_success
    done
    run /usr/bin/plutil -extract ProgramArguments.0 raw -expect string "$plist"
    assert_success
    [ "$output" = "/usr/bin/hidutil" ]
    run /usr/bin/plutil -extract ProgramArguments.1 raw -expect string "$plist"
    assert_success
    [ "$output" = "property" ]
    run /usr/bin/plutil -extract ProgramArguments.2 raw -expect string "$plist"
    assert_success
    [ "$output" = "--set" ]
    run /usr/bin/plutil -extract ProgramArguments.3 raw -expect string "$plist"
    assert_success
    [ "$output" = '{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0x700000039,"HIDKeyboardModifierMappingDst":0x7000000E0}]}' ]
    run /usr/bin/plutil -extract RunAtLoad raw -expect bool "$plist"
    assert_success
    [ "$output" = "true" ]
    run /usr/bin/plutil -extract ProgramArguments.4 raw -expect string "$plist"
    assert_failure

    run /usr/bin/grep -Fx -- "bootstrap gui/$(id -u) $target" "$COMMAND_LOG"
    assert_success
}

@test "macos sync writes the declared typed device defaults" {
    run bash "$SYNC_SCRIPT"
    assert_success

    local expected
    for expected in \
        "write com.apple.driver.AppleMultitouchTrackpad TrackpadRightClick -bool true" \
        "write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadRightClick -bool true" \
        "write NSGlobalDomain com.apple.trackpad.enableSecondaryClick -bool true" \
        "write com.apple.driver.AppleBluetoothMultitouch.mouse MouseButtonMode -string TwoButton" \
        "write com.apple.AppleMultitouchMouse mouseButtonMode -string TwoButton" \
        "write com.cmuxterm.app browserOpenTerminalLinksInCmuxBrowser -bool false"; do
        run /usr/bin/grep -Fx -- "$expected" "$COMMAND_LOG"
        assert_success
    done
}

@test "macos sync stops before agents when symbolic-hotkey export fails" {
    cat > "$MOCK_BIN/defaults" <<'MOCK'
#!/bin/bash
if [[ "$1" == "export" ]]; then
    exit 42
fi
printf '%s\n' "$*" >> "$COMMAND_LOG"
exit 0
MOCK
    chmod +x "$MOCK_BIN/defaults"

    run bash "$SYNC_SCRIPT"
    assert_failure
    [ "$status" -eq 42 ]
    local target="$HOME/Library/LaunchAgents/com.local.KeyRemapping.plist"
    run /usr/bin/grep -Fx -- "bootstrap gui/$(id -u) $target" "$COMMAND_LOG"
    assert_failure
    [ ! -e "$target" ]
}
