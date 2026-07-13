#!/usr/bin/env bats
# Tests for the window-management sync libs: rectangle/lib.sh, alfred/lib.sh,
# alttab/lib.sh. Externals (defaults, uname) are mocked via $PATH stubs.

# Libs are sourced by variable path, so shellcheck can't follow them (SC1090);
# ALTTAB_DIR is set inside the sourced lib, not this file (SC2153).
# shellcheck disable=SC1090,SC2153
load test_helper

RECT_LIB="$REAL_DOTFILES_DIR/rectangle/lib.sh"
ALFRED_LIB="$REAL_DOTFILES_DIR/alfred/lib.sh"
ALTTAB_LIB="$REAL_DOTFILES_DIR/alttab/lib.sh"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export DEFAULTS_LOG="$TEST_HOME/defaults.log"
    : > "$DEFAULTS_LOG"
    write_mock_uname "Darwin"
    write_mock_defaults
    write_mock_killall
    export PATH="$MOCK_BIN:$PATH"
}

teardown() { teardown_test_env; }

write_mock_uname() {
    printf '#!/bin/bash\necho "%s"\n' "$1" > "$MOCK_BIN/uname"
    chmod +x "$MOCK_BIN/uname"
}

write_mock_defaults() {
    cat > "$MOCK_BIN/defaults" << 'MOCK'
#!/bin/bash
case "$1" in
  read)   [[ -n "${MOCK_DEFAULTS_READ_OK:-}" ]] && exit 0 || exit 1 ;;
  export) printf 'plist\n' > "$3"; exit 0 ;;
  *)      echo "$*" >> "$DEFAULTS_LOG"; exit 0 ;;
esac
MOCK
    chmod +x "$MOCK_BIN/defaults"
}

write_mock_killall() {
    cat > "$MOCK_BIN/killall" << 'MOCK'
#!/bin/bash
echo "killall $*" >> "$DEFAULTS_LOG"
exit 0
MOCK
    chmod +x "$MOCK_BIN/killall"
}

# ── rectangle/lib.sh ────────────────────────────────────────────────────────

@test "rectangle_shortcuts: emits exactly 19 shortcut rows" {
    source "$RECT_LIB"
    run rectangle_shortcuts
    assert_success
    [ "${#lines[@]}" -eq 19 ]
}

@test "rectangle_shortcuts: command names are unique (no clobbering)" {
    source "$RECT_LIB"
    dupes=$(rectangle_shortcuts | cut -d'|' -f1 | sort | uniq -d)
    [ -z "$dupes" ]
}

@test "rectangle_shortcuts: (keyCode, modifierFlags) pairs are unique (no keybind collisions)" {
    source "$RECT_LIB"
    dupes=$(rectangle_shortcuts | cut -d'|' -f2,3 | sort | uniq -d)
    [ -z "$dupes" ]
}

@test "rectangle_write_shortcuts: writes numeric-typed dict leaves per shortcut" {
    source "$RECT_LIB"
    rectangle_write_shortcuts com.test
    run cat "$DEFAULTS_LOG"
    # -dict-add ... -float lands NSNumber leaves per Rectangle's documented
    # schema; the old ASCII plist-dict string form lands NSString (parser ignores).
    assert_output_contains "write com.test leftHalf -dict-add keyCode -float 123 modifierFlags -float 1835008"
    assert_output_contains "write com.test firstThird -dict-add keyCode -float 2 modifierFlags -float 786432"
    assert_output_contains "write com.test topLeft -dict-add keyCode -float 123 modifierFlags -float 917504"
}

@test "rectangle_write_shortcuts: writes all 19 shortcuts plus 3 quality-of-life defaults" {
    source "$RECT_LIB"
    rectangle_write_shortcuts com.test
    count=$(grep -c '^write com.test' "$DEFAULTS_LOG")
    [ "$count" -eq 22 ]
}

@test "rectangle_sync: skips on non-Darwin without writing defaults" {
    write_mock_uname "Linux"
    source "$RECT_LIB"
    run rectangle_sync
    assert_success
    assert_output_contains "skipping (not macOS)"
    [ ! -s "$DEFAULTS_LOG" ]
}

# ── alfred/lib.sh ────────────────────────────────────────────────────────────

@test "alfred_current_sync_folder: returns the .current value when present" {
    source "$ALFRED_LIB"
    prefs="$TEST_HOME/prefs.json"
    printf '{"current":"/path/to/dots/alfred"}\n' > "$prefs"
    run alfred_current_sync_folder "$prefs"
    assert_success
    [ "$output" = "/path/to/dots/alfred" ]
}

@test "alfred_current_sync_folder: falls back to .syncfolder when .current is absent" {
    source "$ALFRED_LIB"
    prefs="$TEST_HOME/prefs.json"
    printf '{"syncfolder":"/path/to/dots/alfred"}\n' > "$prefs"
    run alfred_current_sync_folder "$prefs"
    assert_success
    [ "$output" = "/path/to/dots/alfred" ]
}

@test "alfred_current_sync_folder: prefers .current over .syncfolder when both exist" {
    source "$ALFRED_LIB"
    prefs="$TEST_HOME/prefs.json"
    printf '{"current":"/from/current","syncfolder":"/from/syncfolder"}\n' > "$prefs"
    run alfred_current_sync_folder "$prefs"
    assert_success
    [ "$output" = "/from/current" ]
}

@test "alfred_current_sync_folder: returns empty when neither key is set" {
    source "$ALFRED_LIB"
    prefs="$TEST_HOME/prefs.json"
    printf '{"other":"x"}\n' > "$prefs"
    run alfred_current_sync_folder "$prefs"
    assert_success
    [ -z "$output" ]
}

@test "alfred_current_sync_folder: warns and skips (rc 2) when jq is absent" {
    source "$ALFRED_LIB"
    prefs="$TEST_HOME/prefs.json"
    printf '{"current":"/path/to/dots/alfred"}\n' > "$prefs"
    # PATH holds only the mock bin (uname/defaults/killall), so jq is not found.
    PATH="$MOCK_BIN" run alfred_current_sync_folder "$prefs"
    [ "$status" -eq 2 ]
    assert_output_contains "jq not found"
}

@test "alfred_sync: reports success when sync folder already points at the dotfiles dir" {
    source "$ALFRED_LIB"
    export ALFRED_APP="$TEST_HOME/Alfred.app"; mkdir -p "$ALFRED_APP"
    export ALFRED_DIR="$TEST_HOME/dots/alfred"; mkdir -p "$ALFRED_DIR/Alfred.alfredpreferences"
    export ALFRED_PREFS_JSON="$TEST_HOME/prefs.json"
    printf '{"current":"%s"}\n' "$ALFRED_DIR" > "$ALFRED_PREFS_JSON"
    run alfred_sync
    assert_success
    assert_output_contains "sync folder already points at $ALFRED_DIR"
}

@test "alfred_sync: notes missing Alfred.alfredpreferences package when folder points here" {
    source "$ALFRED_LIB"
    export ALFRED_APP="$TEST_HOME/Alfred.app"; mkdir -p "$ALFRED_APP"
    export ALFRED_DIR="$TEST_HOME/dots/alfred"; mkdir -p "$ALFRED_DIR"
    export ALFRED_PREFS_JSON="$TEST_HOME/prefs.json"
    printf '{"current":"%s"}\n' "$ALFRED_DIR" > "$ALFRED_PREFS_JSON"
    run alfred_sync
    assert_success
    assert_output_contains "sync folder already points at $ALFRED_DIR"
    assert_output_contains "no Alfred.alfredpreferences package in this dir yet"
}

@test "alfred_sync: emits one-time setup guidance when sync folder points elsewhere" {
    source "$ALFRED_LIB"
    export ALFRED_APP="$TEST_HOME/Alfred.app"; mkdir -p "$ALFRED_APP"
    export ALFRED_DIR="$TEST_HOME/dots/alfred"; mkdir -p "$ALFRED_DIR"
    export ALFRED_PREFS_JSON="$TEST_HOME/prefs.json"
    printf '{"current":"/somewhere/else"}\n' > "$ALFRED_PREFS_JSON"
    run alfred_sync
    assert_success
    assert_output_contains "is not pointing at this dotfiles dir"
    assert_output_contains "current: /somewhere/else"
    assert_output_contains "pick: $ALFRED_DIR"
}

# ── alttab/lib.sh ────────────────────────────────────────────────────────────

@test "alttab/lib.sh: derives bundle and plist path once for both entry points" {
    source "$ALTTAB_LIB"
    [ "$ALTTAB_BUNDLE" = "com.lwouis.alt-tab-macos" ]
    [ "$ALTTAB_PLIST" = "$ALTTAB_DIR/com.lwouis.alt-tab-macos.plist" ]
}

@test "alttab_export: fails with guidance when no preferences exist" {
    source "$ALTTAB_LIB"
    export ALTTAB_PLIST="$TEST_HOME/at.plist"
    run alttab_export
    assert_failure
    assert_output_contains "no preferences found"
    [ ! -f "$TEST_HOME/at.plist" ]
}

@test "alttab_export: exports the plist and confirms the path when prefs exist" {
    export MOCK_DEFAULTS_READ_OK=1
    source "$ALTTAB_LIB"
    export ALTTAB_PLIST="$TEST_HOME/at.plist"
    run alttab_export
    assert_success
    assert_output_contains "wrote $TEST_HOME/at.plist"
    [ -f "$TEST_HOME/at.plist" ]
}

@test "alttab_sync: skips on non-Darwin" {
    write_mock_uname "Linux"
    source "$ALTTAB_LIB"
    run alttab_sync
    assert_success
    assert_output_contains "skipping (not macOS)"
}

@test "alttab_sync: imports the plist and prints the overwrite reminder when configured" {
    source "$ALTTAB_LIB"
    export ALTTAB_APP="$TEST_HOME/AltTab.app"; mkdir -p "$ALTTAB_APP"
    export ALTTAB_PLIST="$TEST_HOME/at.plist"; printf 'plist\n' > "$ALTTAB_PLIST"
    run alttab_sync
    assert_success
    assert_output_contains "imported preferences from at.plist"
    assert_output_contains "sync overwrites UI changes - run alttab/.export first to keep them"
    run cat "$DEFAULTS_LOG"
    assert_output_contains "import com.lwouis.alt-tab-macos $TEST_HOME/at.plist"
}
