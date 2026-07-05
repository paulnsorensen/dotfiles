#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2030,SC2031,SC2034,SC2317
# Tests for chezmoi/lib/install-codex.sh — first-time scaffold plus
# non-destructive default backfill for older user-owned ~/.codex/config.toml
# files.

load test_helper

setup() {
    setup_test_env
    INSTALLER="$REAL_DOTFILES_DIR/chezmoi/lib/install-codex.sh"
    SRC_DIR="$TEST_HOME/codex-src"
    mkdir -p "$SRC_DIR"
    cat > "$SRC_DIR/config.toml" <<'TOML'
model = "gpt-5"
approval_policy = "on-request"
TOML
}

teardown() { teardown_test_env; }

@test "install-codex.sh prints usage and exits 2 with no args" {
    run bash "$INSTALLER"
    [[ "$status" -eq 2 ]]
    assert_output_contains "Usage:"
}

@test "install-codex.sh fails when source directory is missing" {
    run bash "$INSTALLER" "$TEST_HOME/does-not-exist"
    assert_failure
    assert_output_contains "source directory not found"
}

@test "install-codex.sh scaffolds config.toml on a fresh \$HOME" {
    export CODEX_HOME="$TEST_HOME/.codex"
    [[ ! -e "$CODEX_HOME/config.toml" ]]
    run bash "$INSTALLER" "$SRC_DIR"
    assert_success
    assert_output_contains "Scaffolded"
    [[ "$(yq -p=toml '.model' "$CODEX_HOME/config.toml")" == "gpt-5" ]]
    [[ "$(yq -p=toml '.approval_policy' "$CODEX_HOME/config.toml")" == "on-request" ]]
    [[ "$(yq -p=toml '.sandbox_mode' "$CODEX_HOME/config.toml")" == "workspace-write" ]]
    [[ "$(yq -p=toml '.sandbox_workspace_write.network_access' "$CODEX_HOME/config.toml")" == "true" ]]
    [[ "$(yq -p=toml '.tui.input_mode' "$CODEX_HOME/config.toml")" == "vim" ]]
}

@test "install-codex.sh backfills defaults without clobbering existing user config" {
    export CODEX_HOME="$TEST_HOME/.codex"
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'USER'
# User customisations the installer must not clobber.
model = "gpt-codex-user"
[mcp_servers.custom]
command = "my-tool"
USER
    run bash "$INSTALLER" "$SRC_DIR"
    assert_success
    assert_output_contains "backfilled missing defaults"
    [[ "$(yq -p=toml '.model' "$CODEX_HOME/config.toml")" == "gpt-codex-user" ]]
    [[ "$(yq -p=toml '.mcp_servers.custom.command' "$CODEX_HOME/config.toml")" == "my-tool" ]]
    [[ "$(yq -p=toml '.approval_policy' "$CODEX_HOME/config.toml")" == "on-request" ]]
    [[ "$(yq -p=toml '.sandbox_mode' "$CODEX_HOME/config.toml")" == "workspace-write" ]]
    [[ "$(yq -p=toml '.sandbox_workspace_write.network_access' "$CODEX_HOME/config.toml")" == "true" ]]
    [[ "$(yq -p=toml '.tui.input_mode' "$CODEX_HOME/config.toml")" == "vim" ]]
}

@test "install-codex.sh honors CODEX_HOME override" {
    export CODEX_HOME="$TEST_HOME/elsewhere/codex"
    run bash "$INSTALLER" "$SRC_DIR"
    assert_success
    assert_file_exists "$CODEX_HOME/config.toml"
    [[ ! -e "$HOME/.codex/config.toml" ]]
}

@test "install-codex.sh is a no-op when source has no config.toml" {
    rm "$SRC_DIR/config.toml"
    export CODEX_HOME="$TEST_HOME/.codex"
    run bash "$INSTALLER" "$SRC_DIR"
    assert_success
    [[ ! -e "$CODEX_HOME/config.toml" ]]
}

@test "install-codex.sh second run on a scaffolded config is a no-op" {
    export CODEX_HOME="$TEST_HOME/.codex"
    run bash "$INSTALLER" "$SRC_DIR"
    assert_success
    # Mutate the scaffolded file as if the user (or `codex mcp add`) had touched it.
    echo '# user edit' >> "$CODEX_HOME/config.toml"
    local before; before=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    run bash "$INSTALLER" "$SRC_DIR"
    assert_success
    local after; after=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    [[ "$before" == "$after" ]]
}
