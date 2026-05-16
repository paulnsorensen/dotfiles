#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for chezmoi/lib/install-codex.sh — first-time-only scaffold of
# ~/.codex/config.toml. Once the user's config exists, the installer leaves
# it alone so `codex mcp add` (and any user edits) survive subsequent syncs.

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
    assert_file_exists "$CODEX_HOME/config.toml"
    grep -q 'model = "gpt-5"' "$CODEX_HOME/config.toml"
}

@test "install-codex.sh preserves an existing user-owned config.toml" {
    export CODEX_HOME="$TEST_HOME/.codex"
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'USER'
# User customisations the installer must not clobber.
model = "gpt-codex-user"
[mcp_servers.custom]
command = "my-tool"
USER
    local before; before=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    run bash "$INSTALLER" "$SRC_DIR"
    assert_success
    assert_output_contains "Skipped"
    local after; after=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    [[ "$before" == "$after" ]]
    grep -q 'gpt-codex-user' "$CODEX_HOME/config.toml"
    grep -q 'my-tool'        "$CODEX_HOME/config.toml"
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
