#!/usr/bin/env bats
# Tests for packages/sync.sh
#
# Integration tests run the real sync script with a mock brew/cargo
# that records calls instead of installing. This verifies the full
# flow: YAML parsing → platform filtering → install decisions → cache.

load test_helper

SYNC_SCRIPT="$REAL_DOTFILES_DIR/packages/sync.sh"

setup() {
    setup_test_env
    export PACKAGES_FILE="$TEST_HOME/packages.yaml"
    export CACHE_DIR="$TEST_HOME/cache"
    export CACHE_FILE="$CACHE_DIR/packages.hash"
    mkdir -p "$CACHE_DIR"

    # Mock bin directory — prepended to PATH so mock brew/cargo are found first
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"

    # Log file where mock brew records every call
    export BREW_LOG="$TEST_HOME/brew.log"
    export CARGO_LOG="$TEST_HOME/cargo.log"

    # Create mock brew
    cat > "$MOCK_BIN/brew" << 'MOCKBREW'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
case "$1" in
    list)   echo "" ;;          # nothing installed
    tap)
        if [[ $# -eq 1 ]]; then
            echo ""             # no taps
        fi
        ;;                      # brew tap <name> succeeds silently
    install) ;;                 # succeed silently
esac
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"

    # Create mock cargo
    cat > "$MOCK_BIN/cargo" << 'MOCKCARGO'
#!/bin/bash
echo "cargo $*" >> "$CARGO_LOG"
case "$1" in
    install)
        if [[ "$2" == "--list" ]]; then
            echo ""
        fi
        ;;
esac
exit 0
MOCKCARGO
    chmod +x "$MOCK_BIN/cargo"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

# Helper: write a test packages.yaml
write_test_yaml() {
    cat > "$PACKAGES_FILE" << 'YAML'
packages:
  - test/tap-repo: { source: tap }
  - curl
  - jq
  - fd: { apt: fd-find }
  - node: { apt: nodejs }
  - mas: { platform: mac }
  - xclip: { platform: linux }
  - docker: { source: cask, dev: true, platform: mac }
  - npm: { platform: linux, dev: true }
  - pyenv: { dev: true }
  - lspmux:
      source: cargo
      git: https://example.com/lspmux.git
YAML
}

# Helper: run the sync script with FORCE_PACKAGES to skip cache
run_sync() {
    FORCE_PACKAGES=true run bash "$SYNC_SCRIPT"
}

# --- Schema validation (against real packages.yaml) ---

@test "packages.yaml is valid YAML" {
    run yq '.' "$REAL_DOTFILES_DIR/packages.yaml"
    assert_success
}

@test "all platform values are mac or linux" {
    run yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.platform != null) | .value.platform' \
        "$REAL_DOTFILES_DIR/packages.yaml"
    assert_success
    while IFS= read -r platform; do
        [[ -z "$platform" ]] && continue
        [[ "$platform" == "mac" || "$platform" == "linux" ]]
    done <<< "$output"
}

@test "all source values are brew, cask, tap, or cargo" {
    run yq -r '.packages[] | select(kind == "map") | to_entries[0] | select(.value.source != null) | .value.source' \
        "$REAL_DOTFILES_DIR/packages.yaml"
    assert_success
    while IFS= read -r source; do
        [[ -z "$source" ]] && continue
        [[ "$source" == "brew" || "$source" == "cask" || "$source" == "tap" || "$source" == "cargo" ]]
    done <<< "$output"
}

@test "no duplicate package names" {
    local names
    names=$(
        yq -r '.packages[] | select(kind == "scalar")' "$REAL_DOTFILES_DIR/packages.yaml"
        yq -r '.packages[] | select(kind == "map") | to_entries[0] | .key' "$REAL_DOTFILES_DIR/packages.yaml"
    )
    local dupes
    dupes=$(echo "$names" | sort | uniq -d)
    if [[ -n "$dupes" ]]; then
        echo "Duplicate packages found: $dupes" >&2
        return 1
    fi
}

# --- Integration: sync installs the right packages ---

@test "sync installs bare-string formulae via brew" {
    write_test_yaml
    run_sync
    assert_success

    # curl and jq are bare strings — should be passed to brew install
    grep -q "brew install curl" "$BREW_LOG"
    grep -q "brew install jq" "$BREW_LOG"
}

@test "sync installs map formulae (fd, node) via brew" {
    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install fd" "$BREW_LOG"
    grep -q "brew install node" "$BREW_LOG"
}

@test "sync installs mac-only packages on Darwin" {
    # This test only runs on macOS (where uname == Darwin)
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    run_sync
    assert_success

    grep -q "brew install mas" "$BREW_LOG"
}

@test "sync excludes linux-only packages on Darwin" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    run_sync
    assert_success

    ! grep -q "brew install xclip" "$BREW_LOG"
}

@test "sync processes taps before formulae" {
    write_test_yaml
    run_sync
    assert_success

    # tap line should appear before any install line
    local tap_line install_line
    tap_line=$(grep -n "brew tap test/tap-repo" "$BREW_LOG" | head -1 | cut -d: -f1)
    install_line=$(grep -n "brew install " "$BREW_LOG" | head -1 | cut -d: -f1)
    [[ "$tap_line" -lt "$install_line" ]]
}

@test "sync skips dev packages when DOTFILES_DEV is not set" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    unset DOTFILES_DEV
    run_sync
    assert_success

    ! grep -q "brew install pyenv" "$BREW_LOG"
    ! grep -q "brew install.*docker" "$BREW_LOG"
}

@test "sync installs dev packages when DOTFILES_DEV=true" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    DOTFILES_DEV=true run_sync
    assert_success

    grep -q "brew install pyenv" "$BREW_LOG"
}

@test "sync installs dev casks when DOTFILES_DEV=true" {
    [[ "$(uname)" == "Darwin" ]] || skip "macOS only"

    write_test_yaml
    DOTFILES_DEV=true run_sync
    assert_success

    grep -q "brew install --cask docker" "$BREW_LOG"
}

@test "sync skips already-installed packages" {
    write_test_yaml

    # Mock brew list to report curl as installed
    cat > "$MOCK_BIN/brew" << 'MOCKBREW'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
case "$1" in
    list)
        if [[ "$2" == "--formulae" ]]; then
            echo "curl"
        else
            echo ""
        fi
        ;;
    tap)
        if [[ $# -eq 1 ]]; then echo ""; fi
        ;;
    install) ;;
esac
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"

    run_sync
    assert_success

    # curl should NOT appear in brew install calls
    ! grep -q "brew install curl" "$BREW_LOG"
    # jq should still be installed
    grep -q "brew install jq" "$BREW_LOG"
}

@test "sync installs cargo packages" {
    write_test_yaml
    run_sync
    assert_success

    grep -q "cargo install --git https://example.com/lspmux.git lspmux" "$CARGO_LOG"
}

# --- Integration: cache behavior ---

@test "sync saves cache on success" {
    write_test_yaml
    run_sync
    assert_success

    [[ -f "$CACHE_FILE" ]]
    local expected
    expected=$(shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1)
    [[ "$(cat "$CACHE_FILE")" == "$expected" ]]
}

@test "sync skips when cache matches" {
    write_test_yaml

    # Pre-seed the cache with matching hash
    shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"

    # Run WITHOUT force — should hit cache
    run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "unchanged (cached), skipping"

    # No brew calls should have happened
    [[ ! -f "$BREW_LOG" ]]
}

@test "FORCE_PACKAGES bypasses valid cache" {
    write_test_yaml

    # Pre-seed matching cache
    shasum -a 256 "$PACKAGES_FILE" | cut -d' ' -f1 > "$CACHE_FILE"

    run_sync
    assert_success
    assert_output_contains "bypassing cache"

    # Brew calls should have happened
    [[ -f "$BREW_LOG" ]]
}

@test "sync does NOT save cache when brew install fails" {
    write_test_yaml

    # Mock brew that fails on 'jq'
    cat > "$MOCK_BIN/brew" << 'MOCKBREW'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
case "$1" in
    list)   echo "" ;;
    tap)    if [[ $# -eq 1 ]]; then echo ""; fi ;;
    install)
        if [[ "$2" == "jq" || "$3" == "jq" ]]; then
            exit 1
        fi
        ;;
esac
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"

    run_sync

    # Cache should NOT exist
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]
    assert_output_contains "failed to install"
    assert_output_contains "cache NOT saved"
}

@test "sync retries after previous failure (no cache)" {
    write_test_yaml

    # First run: brew fails on jq
    cat > "$MOCK_BIN/brew" << 'MOCKBREW'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
case "$1" in
    list)   echo "" ;;
    tap)    if [[ $# -eq 1 ]]; then echo ""; fi ;;
    install)
        if [[ "$2" == "jq" || "$3" == "jq" ]]; then exit 1; fi
        ;;
esac
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"

    # First run — fails, no cache saved
    run bash "$SYNC_SCRIPT"
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]

    # Fix brew and re-run — should NOT skip (no cache)
    rm -f "$BREW_LOG"
    cat > "$MOCK_BIN/brew" << 'MOCKBREW'
#!/bin/bash
echo "brew $*" >> "$BREW_LOG"
case "$1" in
    list)   echo "" ;;
    tap)    if [[ $# -eq 1 ]]; then echo ""; fi ;;
    install) ;;
esac
exit 0
MOCKBREW
    chmod +x "$MOCK_BIN/brew"

    run bash "$SYNC_SCRIPT"
    assert_success

    # Now cache should be saved
    [[ -f "$CACHE_FILE" ]]
    grep -q "brew install jq" "$BREW_LOG"
}

# --- Integration: missing toolchain ---

@test "sync counts missing cargo AND rustup as failure (no cache saved)" {
    write_test_yaml

    # Remove both mocks so neither is found
    rm -f "$MOCK_BIN/cargo"
    rm -f "$MOCK_BIN/rustup"

    run_sync

    # Should warn about cargo and not save cache
    assert_output_contains "cargo not found"
    assert_output_contains "cache NOT saved"
    [[ ! -f "$CACHE_FILE" ]] || [[ ! -s "$CACHE_FILE" ]]
}

@test "sync bootstraps rust toolchain when rustup exists but cargo missing" {
    write_test_yaml

    # Remove cargo mock
    rm -f "$MOCK_BIN/cargo"

    # Create mock rustup that "installs" cargo
    cat > "$MOCK_BIN/rustup" << MOCKRUSTUP
#!/bin/bash
echo "rustup \$*" >> "$CARGO_LOG"
# Simulate: after 'rustup default stable', cargo becomes available
# Create a mock cargo in the same bin dir
cat > "$MOCK_BIN/cargo" << 'INNERCARGO'
#!/bin/bash
echo "cargo \$*" >> "$CARGO_LOG"
case "\$1" in
    install)
        if [[ "\$2" == "--list" ]]; then echo ""; fi
        ;;
esac
exit 0
INNERCARGO
chmod +x "$MOCK_BIN/cargo"
exit 0
MOCKRUSTUP
    chmod +x "$MOCK_BIN/rustup"

    run_sync
    assert_success

    assert_output_contains "Bootstrapping Rust stable toolchain"
    # Cargo packages should have been installed after bootstrap
    grep -q "cargo install --git" "$CARGO_LOG"
}

# --- Integration: QUICK_SYNC ---

@test "QUICK_SYNC skips everything" {
    write_test_yaml
    QUICK_SYNC=true run bash "$SYNC_SCRIPT"
    assert_success
    assert_output_contains "Quick sync, skipping"
    [[ ! -f "$BREW_LOG" ]]
}
