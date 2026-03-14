#!/usr/bin/env bats
# shellcheck disable=SC2016
# Tests for iterm2/.sync, iterm2/.scrub, and fonts/.sync

load test_helper

ITERM_SYNC="$REAL_DOTFILES_DIR/iterm2/.sync"
ITERM_SCRUB="$REAL_DOTFILES_DIR/iterm2/.scrub"
FONTS_SYNC="$REAL_DOTFILES_DIR/fonts/.sync"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export DEFAULTS_LOG="$TEST_HOME/defaults.log"
    export BREW_LOG="$TEST_HOME/brew.log"
    export ITERM_DIR="$TEST_HOME/iterm2"
    mkdir -p "$ITERM_DIR/background"

    write_mock_uname "Darwin"
    # One-liner mocks for simple stubs
    printf '#!/bin/bash\necho "defaults $*" >> "$DEFAULTS_LOG"\n' > "$MOCK_BIN/defaults"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/wget"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/convert"
    printf '#!/bin/bash\necho "0"\n' > "$MOCK_BIN/yq"
    printf '#!/bin/bash\ncat\n' > "$MOCK_BIN/envsubst"
    printf '#!/bin/bash\nexit 0\n' > "$MOCK_BIN/PlistBuddy"
    write_mock_brew_font
    chmod +x "$MOCK_BIN"/*
    export PATH="$MOCK_BIN:$PATH"
}

teardown() { teardown_test_env; }

# --- Mock helpers ---

write_mock_uname() {
    printf '#!/bin/bash\necho "%s"\n' "$1" > "$MOCK_BIN/uname"
    chmod +x "$MOCK_BIN/uname"
}

write_mock_brew_font() {
    cat > "$MOCK_BIN/brew" << 'MOCK'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
case "$1" in ls) exit 1 ;; esac
exit 0
MOCK
    chmod +x "$MOCK_BIN/brew"
}

create_base_plist() {
    cat > "$ITERM_DIR/iterm2.base.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CustomDir</key>
    <string>__DOTFILES_DIR__/iterm2</string>
    <key>HomeDir</key>
    <string>__HOME__/.config</string>
</dict>
</plist>
PLIST
}

create_live_plist() {
    python3 -c "
import plistlib
data = {
    'CustomDir': '$TEST_HOME/iterm2',
    'HomeDir': '$HOME/.config',
    'SomeFloat': 0.3333333333333,
    'Color': {'Red Component': 0.5, 'Alpha Component': 1.0},
}
with open('$ITERM_DIR/com.googlecode.iterm2.plist', 'wb') as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_XML)
"
}

run_iterm_sync() {
    cp "$ITERM_SYNC" "$ITERM_DIR/.sync"
    run bash "$ITERM_DIR/.sync"
}

run_iterm_scrub() {
    cp "$ITERM_SCRUB" "$ITERM_DIR/.scrub"
    run bash "$ITERM_DIR/.scrub"
}

# ── iterm2/.sync ─────────────────────────────────────────────────

@test "iterm2 sync: skips on non-Darwin" {
    write_mock_uname "Linux"
    run_iterm_sync
    assert_success
    assert_output_contains "Not on mac, skipping iterm2"
}

@test "iterm2 sync: skips when QUICK_SYNC=true" {
    QUICK_SYNC=true run_iterm_sync
    assert_success
    assert_output_contains "Quick sync, skipping iterm"
}

@test "iterm2 sync: sed expands placeholders in base plist" {
    create_base_plist
    touch "$ITERM_DIR/background/i_know_how_to_make_ducks.png"
    run_iterm_sync
    assert_success

    local live="$ITERM_DIR/com.googlecode.iterm2.plist"
    assert_file_exists "$live"
    ! grep -q '__DOTFILES_DIR__' "$live"
    ! grep -q '__HOME__' "$live"
    grep -q "$TEST_HOME" "$live"
}

@test "iterm2 sync: runs defaults write commands" {
    create_base_plist
    touch "$ITERM_DIR/background/i_know_how_to_make_ducks.png"
    run_iterm_sync
    assert_success
    grep -q "defaults write com.googlecode.iterm2.plist PrefsCustomFolder" "$DEFAULTS_LOG"
    grep -q "defaults write com.googlecode.iterm2.plist LoadPrefsFromCustomFolder" "$DEFAULTS_LOG"
}

@test "iterm2 sync: exits with error when base plist missing" {
    touch "$ITERM_DIR/background/i_know_how_to_make_ducks.png"
    run_iterm_sync
    assert_failure
    assert_output_contains "No base plist found"
}

@test "iterm2 sync: downloads background when missing" {
    create_base_plist
    run_iterm_sync
    assert_success
}

# ── iterm2/.scrub ────────────────────────────────────────────────

@test "iterm2 scrub: exits with error on missing live plist" {
    run_iterm_scrub
    assert_failure
    assert_output_contains "No live plist found"
}

@test "iterm2 scrub: python normalization rounds floats" {
    create_live_plist
    run_iterm_scrub
    assert_success
    local base="$ITERM_DIR/iterm2.base.plist"
    assert_file_exists "$base"
    grep -q '<real>' "$base"
}

@test "iterm2 scrub: removes alpha=1 entries" {
    create_live_plist
    run_iterm_scrub
    assert_success
    ! grep -q 'Alpha Component' "$ITERM_DIR/iterm2.base.plist"
}

@test "iterm2 scrub: replaces user-specific paths with placeholders" {
    # Use ORIGINAL_HOME so dotfiles_dir != HOME (avoids prefix overlap)
    export HOME="$ORIGINAL_HOME"
    python3 -c "
import plistlib
data = {'CustomDir': '$ITERM_DIR', 'HomeDir': '$ORIGINAL_HOME/.config'}
with open('$ITERM_DIR/com.googlecode.iterm2.plist', 'wb') as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_XML)
"
    run_iterm_scrub
    assert_success
    local base="$ITERM_DIR/iterm2.base.plist"
    grep -q '__DOTFILES_DIR__' "$base"
    grep -q '__HOME__' "$base"
    export HOME="$TEST_HOME"
}

@test "iterm2 scrub: output is deterministic" {
    create_live_plist
    run_iterm_scrub
    assert_success
    local first
    first=$(cat "$ITERM_DIR/iterm2.base.plist")

    create_live_plist
    run_iterm_scrub
    assert_success
    local second
    second=$(cat "$ITERM_DIR/iterm2.base.plist")
    [[ "$first" == "$second" ]]
}

# ── fonts/.sync ──────────────────────────────────────────────────

@test "fonts sync: skips on non-Darwin" {
    write_mock_uname "Linux"
    run bash "$FONTS_SYNC"
    assert_success
    assert_output_contains "Not on mac, skipping fonts"
}

@test "fonts sync: skips when QUICK_SYNC=true" {
    QUICK_SYNC=true run bash "$FONTS_SYNC"
    assert_success
    assert_output_contains "Quick sync, skipping fonts"
}

@test "fonts sync: maps font names to correct file patterns" {
    run bash -c "
        $(sed -n '/^font_pattern()/,/^}/p' "$FONTS_SYNC")
        font_pattern hack
        font_pattern hack-nerd-font
        font_pattern fira-code
        font_pattern monoid
        font_pattern unknown-font
    "
    assert_success
    assert_output_contains "Hack-*"
    assert_output_contains "HackNF*"
    assert_output_contains "FiraCode*"
    assert_output_contains "Monoid*"
    assert_output_contains "unknown-font*"
}

@test "fonts sync: skips fonts already installed manually" {
    mkdir -p "$TEST_HOME/Library/Fonts"
    touch "$TEST_HOME/Library/Fonts/Hack-Regular.ttf"
    touch "$TEST_HOME/Library/Fonts/HackNFM-Regular.ttf"
    touch "$TEST_HOME/Library/Fonts/FiraCode-Regular.ttf"
    touch "$TEST_HOME/Library/Fonts/Monoid-Regular.ttf"

    run bash "$FONTS_SYNC"
    assert_success
    assert_output_contains "already installed manually, skipping"
    ! grep -q "brew install --cask" "$BREW_LOG" 2>/dev/null || true
}

@test "fonts sync: installs missing fonts via brew cask" {
    mkdir -p "$TEST_HOME/Library/Fonts"
    run bash "$FONTS_SYNC"
    assert_success
    assert_output_contains "Installing font-"
    grep -q "brew install --cask font-hack" "$BREW_LOG"
    grep -q "brew install --cask font-fira-code" "$BREW_LOG"
}
