#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for chezmoi/lib/install-base-profile.sh — renders the live install
# profiles into every harness via the `ap` tool. Replaces the deploy roles of
# the retired install-mcp / install-hooks / install-claude-skills chezmoi
# scripts (spec curd 7).

load test_helper

setup() {
    setup_test_env
    LIB="$REAL_DOTFILES_DIR/chezmoi/lib/install-base-profile.sh"
    FAKE_BIN="$TEST_HOME/fake-bin"
    mkdir -p "$FAKE_BIN"
    # Record every `ap` invocation (one line per call) for assertions.
    AP_LOG="$TEST_HOME/ap-calls.log"
    cat > "$FAKE_BIN/ap" <<SH
#!/usr/bin/env bash
echo "HOME=$HOME \$*" >> "$AP_LOG"
exit 0
SH
    chmod +x "$FAKE_BIN/ap"
    export PATH="$FAKE_BIN:$PATH"
}

teardown() { teardown_test_env; }

# ── usage / arg handling ─────────────────────────────────────────────────────

@test "install-base-profile.sh exits non-zero with no ap binary" {
    INSTALL_BASE_PROFILE_AP="$TEST_HOME/does-not-exist" \
        run bash "$LIB" "$TEST_HOME"
    [[ "$status" -ne 0 ]]
    assert_output_contains "ap"
}

@test "install-base-profile.sh requires a target arg" {
    run bash "$LIB"
    [[ "$status" -ne 0 ]]
    assert_output_contains "Usage:"
}

# ── two render targets (the core of curd 7) ──────────────────────────────────

@test "install-base-profile.sh renders the four dot-dir harnesses via global" {
    # `global` wraps `base` with target_default=$HOME + the claude marketplace
    # + plugin enablement. The installer forwards $HOME (so the profile's
    # ${HOME} expands against the test sandbox) and intentionally omits
    # --target — the profile resolves it.
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" \
        run bash "$LIB" "$TEST_HOME"
    assert_success
    run cat "$AP_LOG"
    assert_output_contains "install global --harness claude,codex,cursor,copilot"
}

@test "install-base-profile.sh renders opencode under \$HOME/.config/opencode via opencode-global" {
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" \
        run bash "$LIB" "$TEST_HOME"
    assert_success
    run cat "$AP_LOG"
    assert_output_contains "HOME=$TEST_HOME install opencode-global --harness opencode"
    ! grep -qF -- '--target' "$AP_LOG"
}

@test "install-base-profile.sh makes exactly two ap calls" {
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" bash "$LIB" "$TEST_HOME"
    run wc -l < "$AP_LOG"
    [[ "$(echo "$output" | tr -d ' ')" == "2" ]]
}

@test "install-base-profile.sh fails loud when an ap render fails" {
    cat > "$FAKE_BIN/ap" <<'SH'
#!/usr/bin/env bash
exit 7
SH
    chmod +x "$FAKE_BIN/ap"
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" \
        run bash "$LIB" "$TEST_HOME"
    [[ "$status" -ne 0 ]]
}

# ── retired deploy scripts are gone ──────────────────────────────────────────

@test "retired install-mcp chezmoi script is deleted" {
    [[ ! -e "$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-mcp.sh.tmpl" ]]
}

@test "retired install-hooks chezmoi script is deleted" {
    [[ ! -e "$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-hooks.sh.tmpl" ]]
}

@test "retired install-claude-skills chezmoi script is deleted" {
    [[ ! -e "$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-claude-skills.sh.tmpl" ]]
}

@test "install-base-profile chezmoi script exists" {
    [[ -f "$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_onchange_after_install-base-profile.sh.tmpl" ]]
}
