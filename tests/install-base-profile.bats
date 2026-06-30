#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for chezmoi/lib/install-base-profile.sh — compiles and applies the live
# profile via the agent-profile sync library.

load test_helper

setup() {
    setup_test_env
    LIB="$REAL_DOTFILES_DIR/chezmoi/lib/install-base-profile.sh"
    FAKE_BIN="$TEST_HOME/fake-bin"
    mkdir -p "$FAKE_BIN"
    AP_LOG="$TEST_HOME/ap-calls.log"

    cat > "$FAKE_BIN/ap" <<SH
#!/usr/bin/env bash
echo "HOME=$HOME \$*" >> "$AP_LOG"
if [[ "\$1" == "compile" ]]; then
    out=""
    while ((\$#)); do
        case "\$1" in
            --out) out="\$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    mkdir -p "\$out"
    printf '{"drift": []}\n' > "\$out/manifest.json"
fi
exit 0
SH
    chmod +x "$FAKE_BIN/ap"

    cat > "$FAKE_BIN/chezmoi" <<'SH'
#!/usr/bin/env bash
while (($#)); do
    case "$1" in
        --destination) dest="$2"; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "${dest:?}"
SH
    chmod +x "$FAKE_BIN/chezmoi"

    export PATH="$FAKE_BIN:$PATH"
    export AGENT_PROFILE_CACHE_DIR="$TEST_HOME/cache"
    export AGENT_PROFILE_CHEZMOI="$FAKE_BIN/chezmoi"
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

# ── live compile/apply path ─────────────────────────────────────────────────

@test "install-base-profile.sh fetches sources for live profile" {
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" \
        run bash "$LIB" "$TEST_HOME"
    assert_success
    run cat "$AP_LOG"
    assert_output_contains "HOME=$TEST_HOME fetch-sources live"
}

@test "install-base-profile.sh compiles live with a scratch baseline and cache" {
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" \
        run bash "$LIB" "$TEST_HOME"
    assert_success
    run cat "$AP_LOG"
    assert_output_contains "HOME=$TEST_HOME compile live --baseline"
    assert_output_contains "--out $TEST_HOME/cache"
}

@test "install-base-profile.sh applies the compiled manifest" {
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" \
        run bash "$LIB" "$TEST_HOME"
    assert_success
    run cat "$AP_LOG"
    assert_output_contains "HOME=$TEST_HOME apply-compiled $TEST_HOME/cache/manifest.json"
}

@test "install-base-profile.sh makes exactly three ap calls" {
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" bash "$LIB" "$TEST_HOME"
    run wc -l < "$AP_LOG"
    [[ "$(echo "$output" | tr -d ' ')" == "3" ]]
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

@test "install-base-profile.sh forwards drift acceptance" {
    INSTALL_BASE_PROFILE_AP="$FAKE_BIN/ap" \
        run bash "$LIB" "$TEST_HOME" --accept-agent-drift
    assert_success
    run cat "$AP_LOG"
    assert_output_contains "compile live --baseline"
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
