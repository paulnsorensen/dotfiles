#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for chezmoi/lib/install-prompts.sh — adds agents/preamble.md to Codex
# developer instructions without replacing vendor defaults.

load test_helper

setup() {
    setup_test_env
    LIB="$REAL_DOTFILES_DIR/chezmoi/lib/install-prompts.sh"
    PREAMBLE_SRC="$TEST_HOME/preamble.md"
    cat > "$PREAMBLE_SRC" <<'MD'
# Preamble — MCP tool routing

Test preamble content for assertion checks.
MD
    export CODEX_HOME="$TEST_HOME/.codex"
}

teardown() { teardown_test_env; }

# ── usage / arg handling ─────────────────────────────────────────────────────

@test "install-prompts.sh exits 2 with no args" {
    run bash "$LIB"
    [[ "$status" -eq 2 ]]
    assert_output_contains "Usage:"
}

@test "install-prompts.sh is a no-op when preamble file is missing" {
    INSTALL_PROMPTS_HAVE_CODEX=1 \
        run bash "$LIB" "$TEST_HOME/does-not-exist.md"
    assert_success
    [[ ! -e "$CODEX_HOME/preamble.md" ]]
}

# ── Codex wiring ─────────────────────────────────────────────────────────────

@test "install-prompts.sh skips Codex when codex CLI is missing" {
    INSTALL_PROMPTS_HAVE_CODEX=0 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_output_contains "Skipped Codex wiring"
    [[ ! -e "$CODEX_HOME/preamble.md" ]]
}

@test "install-prompts.sh copies preamble.md to \$CODEX_HOME/preamble.md when codex is present" {
    INSTALL_PROMPTS_HAVE_CODEX=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_file_exists "$CODEX_HOME/preamble.md"
    diff "$PREAMBLE_SRC" "$CODEX_HOME/preamble.md"
}

@test "install-prompts.sh skips config.toml edit when it doesn't exist yet" {
    INSTALL_PROMPTS_HAVE_CODEX=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_output_contains "Skipped"
    assert_output_contains "config.toml"
    [[ ! -e "$CODEX_HOME/config.toml" ]]
}

@test "install-prompts.sh adds shared instructions without replacing vendor defaults" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "vendor-model"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_YQ=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    local instructions
    instructions="$(yq -p=toml -r '.developer_instructions' "$CODEX_HOME/config.toml")"
    [[ "$instructions" == *"Test preamble content for assertion checks."* ]]
    [[ "$instructions" != *"model_instructions_file"* ]]
    [[ "$(yq -p=toml -r '.model' "$CODEX_HOME/config.toml")" == "vendor-model" ]]
    [[ "$(yq -p=toml -r '.approval_policy' "$CODEX_HOME/config.toml")" == "on-request" ]]
    [[ "$(yq -p=toml -r '.sandbox_mode' "$CODEX_HOME/config.toml")" == "workspace-write" ]]
}

@test "install-prompts.sh is idempotent and adds the shared block once" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_YQ=1 \
        bash "$LIB" "$PREAMBLE_SRC"
    local before; before=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_YQ=1 \
        bash "$LIB" "$PREAMBLE_SRC"
    local after; after=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    [[ "$before" == "$after" ]]
    [[ "$(yq -p=toml -r '.developer_instructions' "$CODEX_HOME/config.toml" | grep -c 'Test preamble content')" -eq 1 ]]
}

@test "install-prompts.sh skips config.toml edit when yq is unavailable" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_YQ=0 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_output_contains "yq not installed"
    ! grep -q "model_instructions_file" "$CODEX_HOME/config.toml"
}


# ── migration and ownership ──────────────────────────────────────────────────

@test "install-prompts.sh migrates the repo-owned model prompt path" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<TOML
model_instructions_file = "$CODEX_HOME/preamble.md"

[tui.model_availability_nux]
seen = true
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_YQ=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    [[ "$(yq -p=toml -r '.model_instructions_file // ""' "$CODEX_HOME/config.toml")" == "" ]]
    [[ "$(yq -p=toml -r '.developer_instructions' "$CODEX_HOME/config.toml")" == *"Test preamble content"* ]]
    [[ "$(yq -p=toml -r '.tui.model_availability_nux.seen' "$CODEX_HOME/config.toml")" == "true" ]]
}

@test "install-prompts.sh preserves custom model and developer instructions" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
model_instructions_file = "/custom/instructions.md"
developer_instructions = "User custom instructions"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_YQ=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    [[ "$(yq -p=toml -r '.model_instructions_file' "$CODEX_HOME/config.toml")" == "/custom/instructions.md" ]]
    local instructions
    instructions="$(yq -p=toml -r '.developer_instructions' "$CODEX_HOME/config.toml")"
    [[ "$instructions" == *"User custom instructions"* ]]
    [[ "$instructions" == *"Test preamble content"* ]]
    [[ "$(printf '%s' "$instructions" | grep -c 'User custom instructions')" -eq 1 ]]
    [[ "$(printf '%s' "$instructions" | grep -c 'Test preamble content')" -eq 1 ]]
    local before after
    before=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_YQ=1 \
        bash "$LIB" "$PREAMBLE_SRC"
    after=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    [[ "$before" == "$after" ]]
}
