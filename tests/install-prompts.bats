#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for chezmoi/lib/install-prompts.sh — wires agents/preamble.md as the
# replacement system prompt for Codex CLI and opencode.

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
    export OPENCODE_HOME="$TEST_HOME/.config/opencode"
}

teardown() { teardown_test_env; }

# ── usage / arg handling ─────────────────────────────────────────────────────

@test "install-prompts.sh exits 2 with no args" {
    run bash "$LIB"
    [[ "$status" -eq 2 ]]
    assert_output_contains "Usage:"
}

@test "install-prompts.sh is a no-op when preamble file is missing" {
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=1 \
        run bash "$LIB" "$TEST_HOME/does-not-exist.md"
    assert_success
    [[ ! -e "$CODEX_HOME/preamble.md" ]]
    [[ ! -e "$OPENCODE_HOME/agents/build.md" ]]
}

# ── Codex wiring ─────────────────────────────────────────────────────────────

@test "install-prompts.sh skips Codex when codex CLI is missing" {
    INSTALL_PROMPTS_HAVE_CODEX=0 INSTALL_PROMPTS_HAVE_OPENCODE=0 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_output_contains "Skipped Codex wiring"
    [[ ! -e "$CODEX_HOME/preamble.md" ]]
}

@test "install-prompts.sh copies preamble.md to \$CODEX_HOME/preamble.md when codex is present" {
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_file_exists "$CODEX_HOME/preamble.md"
    diff "$PREAMBLE_SRC" "$CODEX_HOME/preamble.md"
}

@test "install-prompts.sh skips config.toml edit when it doesn't exist yet" {
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_output_contains "Skipped"
    assert_output_contains "config.toml"
    [[ ! -e "$CODEX_HOME/config.toml" ]]
}

@test "install-prompts.sh sets model_instructions_file in existing config.toml" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"
sandbox_mode = "workspace-write"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 INSTALL_PROMPTS_HAVE_YQ=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    grep -q "model_instructions_file" "$CODEX_HOME/config.toml"
    local set_path
    set_path="$(yq -p=toml '.model_instructions_file' "$CODEX_HOME/config.toml")"
    [[ "$set_path" == "$CODEX_HOME/preamble.md" ]]
    # Other keys must survive.
    grep -q 'approval_policy = "on-request"' "$CODEX_HOME/config.toml"
    grep -q 'sandbox_mode = "workspace-write"' "$CODEX_HOME/config.toml"
}

@test "install-prompts.sh is idempotent on the config.toml edit" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 INSTALL_PROMPTS_HAVE_YQ=1 \
        bash "$LIB" "$PREAMBLE_SRC"
    local before; before=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 INSTALL_PROMPTS_HAVE_YQ=1 \
        bash "$LIB" "$PREAMBLE_SRC"
    local after; after=$(shasum -a 256 "$CODEX_HOME/config.toml" | awk '{print $1}')
    [[ "$before" == "$after" ]]
}

@test "install-prompts.sh skips config.toml edit when yq is unavailable" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 INSTALL_PROMPTS_HAVE_YQ=0 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_output_contains "yq not installed"
    ! grep -q "model_instructions_file" "$CODEX_HOME/config.toml"
}

# ── opencode wiring ──────────────────────────────────────────────────────────

@test "install-prompts.sh skips opencode when opencode CLI is missing" {
    INSTALL_PROMPTS_HAVE_CODEX=0 INSTALL_PROMPTS_HAVE_OPENCODE=0 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_output_contains "Skipped opencode wiring"
    [[ ! -e "$OPENCODE_HOME/agents/build.md" ]]
}

@test "install-prompts.sh copies preamble.md to opencode agents/build.md when opencode is present" {
    INSTALL_PROMPTS_HAVE_CODEX=0 INSTALL_PROMPTS_HAVE_OPENCODE=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_file_exists "$OPENCODE_HOME/agents/build.md"
    diff "$PREAMBLE_SRC" "$OPENCODE_HOME/agents/build.md"
}

@test "install-prompts.sh creates opencode agents/ dir if absent" {
    [[ ! -d "$OPENCODE_HOME/agents" ]]
    INSTALL_PROMPTS_HAVE_CODEX=0 INSTALL_PROMPTS_HAVE_OPENCODE=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    [[ -d "$OPENCODE_HOME/agents" ]]
}

# ── both harnesses ───────────────────────────────────────────────────────────

@test "install-prompts.sh wires both harnesses when both are present" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=1 INSTALL_PROMPTS_HAVE_YQ=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    assert_file_exists "$CODEX_HOME/preamble.md"
    assert_file_exists "$OPENCODE_HOME/agents/build.md"
    grep -q "model_instructions_file" "$CODEX_HOME/config.toml"
}

# ── regression: model_instructions_file must stay a root-level key (#262) ─────

@test "install-prompts.sh keeps model_instructions_file at root when config.toml ends with a [section]" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"

[tui.model_availability_nux]
seen = true
TOML
    INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 INSTALL_PROMPTS_HAVE_YQ=1 \
        run bash "$LIB" "$PREAMBLE_SRC"
    assert_success
    # Codex reads model_instructions_file as a ROOT key. The old yq -i append
    # dropped it inside the trailing [tui.*] table, so the root read returned "".
    local root_path nested_path seen_val
    root_path="$(yq -p=toml '.model_instructions_file // ""' "$CODEX_HOME/config.toml")"
    nested_path="$(yq -p=toml '.tui.model_availability_nux.model_instructions_file // ""' "$CODEX_HOME/config.toml")"
    seen_val="$(yq -p=toml '.tui.model_availability_nux.seen' "$CODEX_HOME/config.toml")"
    # Single compound assertion so ANY mismatch fails the test (bats checks only
    # the final command's status): root key set, not nested in [tui.*], table kept.
    [[ "$root_path" == "$CODEX_HOME/preamble.md" ]] \
        && [[ "$nested_path" == "" ]] \
        && [[ "$seen_val" == "true" ]]
}

@test "install-prompts.sh does not accumulate duplicate model_instructions_file across runs with a trailing [section]" {
    mkdir -p "$CODEX_HOME"
    cat > "$CODEX_HOME/config.toml" <<'TOML'
approval_policy = "on-request"

[tui.model_availability_nux]
seen = true
TOML
    for _ in 1 2 3; do
        INSTALL_PROMPTS_HAVE_CODEX=1 INSTALL_PROMPTS_HAVE_OPENCODE=0 INSTALL_PROMPTS_HAVE_YQ=1 \
            bash "$LIB" "$PREAMBLE_SRC"
    done
    [[ "$(grep -c 'model_instructions_file' "$CODEX_HOME/config.toml")" -eq 1 ]]
}
