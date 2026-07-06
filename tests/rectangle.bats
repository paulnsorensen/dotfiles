#!/usr/bin/env bats
# shellcheck disable=SC1090  # `source "$LIB"` is a runtime path, not a const
# Tests for rectangle/lib.sh — Rectangle Pro shortcut sync.
#
# The sync writes the SizeUp keymap via `defaults`, then hard-restarts the app
# so the keymap actually loads, and prints an Accessibility notice (the grant is
# macOS-gated and cannot be scripted). Externals (defaults / pkill / open /
# killall / uname) are mocked on $PATH; the app-install check is redirected via
# $RECTANGLE_APP so the Darwin path runs without Rectangle Pro installed.

load test_helper

LIB="$REAL_DOTFILES_DIR/rectangle/lib.sh"

setup() {
    MOCK_BIN="$(mktemp -d)"
    export PATH="$MOCK_BIN:$PATH"
    export MOCK_LOG="$MOCK_BIN/calls.log"
    : > "$MOCK_LOG"

    # Record-only mocks for every external the sync shells out to.
    for tool in defaults pkill open killall; do
        cat > "$MOCK_BIN/$tool" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$MOCK_LOG"
exit 0
EOF
        chmod +x "$MOCK_BIN/$tool"
    done

    # Default: pretend we are on macOS with the app installed.
    _mock_uname Darwin
    APP_DIR="$(mktemp -d)/Rectangle Pro.app"
    mkdir -p "$APP_DIR"
    export RECTANGLE_APP="$APP_DIR"
}

teardown() {
    rm -rf "$MOCK_BIN" "${APP_DIR%/*}"
}

_mock_uname() {
    cat > "$MOCK_BIN/uname" <<EOF
#!/usr/bin/env bash
echo "$1"
EOF
    chmod +x "$MOCK_BIN/uname"
}

# pkill exits non-zero when no process matches; make restart's no-op path testable.
_mock_pkill_nomatch() {
    cat > "$MOCK_BIN/pkill" <<EOF
#!/usr/bin/env bash
printf 'pkill %s\n' "\$*" >> "$MOCK_LOG"
exit 1
EOF
    chmod +x "$MOCK_BIN/pkill"
}

# ── rectangle_restart ──

@test "rectangle_restart hard-kills with pkill -9 then relaunches" {
    source "$LIB"
    run rectangle_restart
    [ "$status" -eq 0 ]
    grep -q 'pkill -9 -f Rectangle Pro' "$MOCK_LOG"
    # relaunch honors $RECTANGLE_APP (not a hardcoded app name)
    grep -qF "open $RECTANGLE_APP" "$MOCK_LOG"
}

@test "rectangle_restart is a no-op (no relaunch) when app is not running" {
    _mock_pkill_nomatch
    source "$LIB"
    run rectangle_restart
    [ "$status" -eq 0 ]
    # pkill found nothing -> we must NOT open (would spawn an unwanted instance)
    ! grep -q '^open ' "$MOCK_LOG"
}

@test "rectangle_restart warns loudly when relaunch fails after a kill" {
    # open exits non-zero (e.g. bundle missing at $RECTANGLE_APP) -> must be loud, not swallowed
    cat > "$MOCK_BIN/open" <<EOF
#!/usr/bin/env bash
printf 'open %s\n' "\$*" >> "$MOCK_LOG"
exit 1
EOF
    chmod +x "$MOCK_BIN/open"
    source "$LIB"
    run rectangle_restart
    [[ "$output" == *"relaunch failed"* ]]
}

# ── rectangle_sync guards ──

@test "rectangle_sync skips on non-macOS and writes nothing" {
    _mock_uname Linux
    source "$LIB"
    run rectangle_sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping (not macOS)"* ]]
    ! grep -q '^defaults ' "$MOCK_LOG"
}

@test "rectangle_sync skips when Rectangle Pro is not installed" {
    export RECTANGLE_APP="/nonexistent/Rectangle Pro.app"
    source "$LIB"
    run rectangle_sync
    [ "$status" -eq 0 ]
    [[ "$output" == *"not installed"* ]]
    ! grep -q '^defaults ' "$MOCK_LOG"
}

# ── rectangle_sync happy path ──

@test "rectangle_sync writes the keymap, restarts, and prints the Accessibility notice" {
    source "$LIB"
    run rectangle_sync
    [ "$status" -eq 0 ]
    # keymap written
    grep -q 'defaults write com.knollsoft.Hookshot leftHalf' "$MOCK_LOG"
    # reloaded so the keymap actually takes effect
    grep -q 'pkill -9 -f Rectangle Pro' "$MOCK_LOG"
    grep -qF "open $RECTANGLE_APP" "$MOCK_LOG"
    # the silent-failure guidance the whole fix exists for
    [[ "$output" == *"Accessibility"* ]]
    [[ "$output" == *"enable Rectangle Pro"* ]]
}

@test "rectangle_sync no longer tells the user to restart manually" {
    source "$LIB"
    run rectangle_sync
    [[ "$output" != *"restart Rectangle Pro to load"* ]]
}
