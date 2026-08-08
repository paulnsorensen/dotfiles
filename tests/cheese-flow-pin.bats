#!/usr/bin/env bats
# Focused coverage for the exact cheese-flow uv-tool pin and the real package
# sync command. Manager mocks keep the clean-bootstrap path network-free.

load test_helper

PACKAGES_YAML="$REAL_DOTFILES_DIR/packages/packages.yaml"
SYNC_SCRIPT="$REAL_DOTFILES_DIR/packages/sync.sh"
CHEESE_FLOW_REV="862d8176cb5e87fc557e30c995fc8b2c7d49270d"
CHEESE_FLOW_PKG="git+https://github.com/paulnsorensen/cheese-flow.git@main"
CHEESE_FLOW_TARGET="git+https://github.com/paulnsorensen/cheese-flow.git@$CHEESE_FLOW_REV"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export PACKAGES_FILE="$PACKAGES_YAML"
    export CACHE_DIR="$TEST_HOME/cache"
    export CACHE_FILE="$CACHE_DIR/packages.hash"
    export MISE_CONFIG_FILE="$TEST_HOME/mise-config.toml"
    mkdir -p "$CACHE_DIR"
    printf '[tools]\n' > "$MISE_CONFIG_FILE"

    export BREW_LOG="$TEST_HOME/brew.log"
    export CARGO_LOG="$TEST_HOME/cargo.log"
    export GH_LOG="$TEST_HOME/gh.log"
    export MISE_LOG="$TEST_HOME/mise.log"
    export NPM_LOG="$TEST_HOME/npm.log"
    export UV_LOG="$TEST_HOME/uv.log"
    export CURL_LOG="$TEST_HOME/curl.log"

    cat > "$MOCK_BIN/brew" <<'MOCKBREW'
#!/bin/bash
printf 'brew %s\n' "$*" >> "$BREW_LOG"
exit 0
MOCKBREW

    cat > "$MOCK_BIN/cargo" <<'MOCKCARGO'
#!/bin/bash
printf 'cargo %s\n' "$*" >> "$CARGO_LOG"
exit 0
MOCKCARGO

    cat > "$MOCK_BIN/gh" <<'MOCKGH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
exit 0
MOCKGH

    cat > "$MOCK_BIN/mise" <<'MOCKMISE'
#!/bin/bash
printf 'mise %s\n' "$*" >> "$MISE_LOG"
exit 0
MOCKMISE

    cat > "$MOCK_BIN/npm" <<'MOCKNPM'
#!/bin/bash
printf 'npm %s\n' "$*" >> "$NPM_LOG"
[[ "$1" == "ls" ]] && printf '{}\n'
exit 0
MOCKNPM

    cat > "$MOCK_BIN/uv" <<'MOCKUV'
#!/bin/bash
printf 'uv %s\n' "$*" >> "$UV_LOG"
exit 0
MOCKUV

    cat > "$MOCK_BIN/curl" <<'MOCKCURL'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CURL_LOG"
exit 0
MOCKCURL

    chmod +x "$MOCK_BIN"/*
    export PATH="$MOCK_BIN:$PATH"
    export DOTFILES_DEV=false
    export UPGRADE_MODE=false
}

teardown() {
    teardown_test_env
}

@test "cheese-flow declares the exact 40-hex revision and no floating revision" {
    local pkg rev flags
    IFS=$'\t' read -r pkg rev flags < <(
        yq -r '.packages[] | select(kind == "map") | select(has("cheese-flow")) | ."cheese-flow" | [.pkg, .rev, (.flags | join(" "))] | @tsv' \
            "$PACKAGES_YAML"
    )

    [[ "$pkg" == "$CHEESE_FLOW_PKG" ]]
    [[ "$rev" == "$CHEESE_FLOW_REV" ]]
    [[ "$rev" =~ ^[0-9a-f]{40}$ ]]
    [[ "$rev" != "main" && "$rev" != "master" && "$rev" != "HEAD" && "$rev" != "latest" ]]
    [[ "$flags" == "--force" ]]
}

@test "cheese-flow has the expected git-refs Renovate annotation" {
    local entry_line annotation
    entry_line=$(grep -n '^  - cheese-flow:' "$PACKAGES_YAML" | cut -d: -f1)
    [[ -n "$entry_line" ]]
    annotation=$(sed -n "$((entry_line - 1))p" "$PACKAGES_YAML")
    [[ "$annotation" == "  # renovate: datasource=git-refs depName=paulnsorensen/cheese-flow" ]]
}

@test "clean package sync reaches the same exact cheese-flow command twice" {
    local expected count
    expected="uv tool install --force $CHEESE_FLOW_TARGET"

    FORCE_PACKAGES=true run bash "$SYNC_SCRIPT"
    assert_success
    FORCE_PACKAGES=true run bash "$SYNC_SCRIPT"
    assert_success

    count=$(grep -Fxc "$expected" "$UV_LOG")
    [[ "$count" == "2" ]]
    ! grep -Fx "uv tool install --force $CHEESE_FLOW_PKG" "$UV_LOG"
}
