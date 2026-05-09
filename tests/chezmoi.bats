#!/usr/bin/env bats
# Tests for chezmoi-managed templates and chezmoi_apply sync helper.

load test_helper

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export CHEZMOI_LOG="$TEST_HOME/chezmoi.log"

    # Mock chezmoi binary that records args and succeeds
    cat > "$MOCK_BIN/chezmoi" << 'MOCK'
#!/bin/bash
printf 'chezmoi %s\n' "$*" >> "${CHEZMOI_LOG:-/dev/null}"
exit 0
MOCK
    chmod +x "$MOCK_BIN/chezmoi"

    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

# shellcheck disable=SC1090
source_sync_lib() {
    SYNC_SCRIPT="$REAL_DOTFILES_DIR/.sync-with-rollback" \
        source "$REAL_DOTFILES_DIR/.sync-lib.sh"
}

@test "chezmoi source dir exists with expected templates" {
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/.chezmoi.toml.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_gitconfig.tmpl"
    assert_file_exists "$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
}

@test ".chezmoi.toml.tmpl prompts for the expected fields" {
    local toml="$REAL_DOTFILES_DIR/chezmoi/.chezmoi.toml.tmpl"
    grep -q 'promptStringOnce . "email"' "$toml"
    grep -q 'promptBoolOnce   . "work"' "$toml"
    grep -q 'promptBoolOnce   . "personal"' "$toml"
    grep -q 'promptBoolOnce   . "dev"' "$toml"
    grep -q 'promptBoolOnce   . "cheese_flow"' "$toml"
    grep -q 'promptBoolOnce   . "vaudeville"' "$toml"
    grep -q 'promptBoolOnce   . "todoist"' "$toml"
}

@test "gitconfig template references .email and gates Uber URLs on .work" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_gitconfig.tmpl"
    grep -q 'email = {{ .email }}' "$tmpl"
    grep -q '{{- if .work }}' "$tmpl"
    grep -q 'code.uber.internal' "$tmpl"
}

@test "copilot template fails fast on missing env vars" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    grep -q 'CONTEXT7_API_KEY is not set' "$tmpl"
    grep -q 'TAVILY_API_KEY is not set' "$tmpl"
    grep -q 'env "CONTEXT7_API_KEY"' "$tmpl"
    grep -q 'env "TAVILY_API_KEY"' "$tmpl"
}

@test "chezmoi is in SYNC_SKIP_LIST so the symlink loop ignores it" {
    source_sync_lib
    run is_skipped "chezmoi"
    assert_success
}

@test "chezmoi_apply skips when chezmoi binary is missing" {
    # Isolate PATH so any system-installed chezmoi isn't picked up
    rm "$MOCK_BIN/chezmoi"
    export PATH="$MOCK_BIN:/usr/bin:/bin"
    source_sync_lib

    run chezmoi_apply "$REAL_DOTFILES_DIR/chezmoi"
    assert_success
    assert_output_contains "chezmoi not installed"
}

@test "chezmoi_apply skips when source dir does not exist" {
    source_sync_lib
    run chezmoi_apply "$TEST_HOME/nonexistent"
    assert_success
    assert_output_contains "chezmoi source dir not found"
}

@test "chezmoi_apply runs apply when config already exists" {
    source_sync_lib

    mkdir -p "$HOME/.config/chezmoi"
    : > "$HOME/.config/chezmoi/chezmoi.toml"

    run chezmoi_apply "$REAL_DOTFILES_DIR/chezmoi"
    assert_success

    run cat "$CHEZMOI_LOG"
    assert_success
    assert_output_contains "chezmoi --source $REAL_DOTFILES_DIR/chezmoi apply"
}

@test "chezmoi_apply skips init when no TTY and config is missing" {
    source_sync_lib

    # No config file, stdin is the bats pipe (not a TTY)
    run chezmoi_apply "$REAL_DOTFILES_DIR/chezmoi"
    assert_success
    assert_output_contains "stdin is not a TTY"

    # No chezmoi calls should have been made
    [[ ! -f "$CHEZMOI_LOG" ]] || ! grep -q '.' "$CHEZMOI_LOG"
}

@test "chezmoi_apply propagates apply failure" {
    source_sync_lib

    # Mock chezmoi that fails on apply
    cat > "$MOCK_BIN/chezmoi" << 'MOCK'
#!/bin/bash
printf 'chezmoi %s\n' "$*" >> "${CHEZMOI_LOG:-/dev/null}"
[[ "$*" == *"apply"* ]] && exit 1
exit 0
MOCK
    chmod +x "$MOCK_BIN/chezmoi"

    mkdir -p "$HOME/.config/chezmoi"
    : > "$HOME/.config/chezmoi/chezmoi.toml"

    run chezmoi_apply "$REAL_DOTFILES_DIR/chezmoi"
    assert_failure
    assert_output_contains "chezmoi apply failed"
}
