#!/usr/bin/env bats
# Infrastructure validation for lspmux integration
# Runs as part of `dots test` to verify lspmux is correctly deployed.
# These are real system checks, not mocked unit tests (see lspmux.bats for those).

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# ===========================================================================
# SECTION 1 — binary and wrappers exist
# ===========================================================================

@test "lspmux binary is installed" {
    command -v lspmux
}

@test "lspmux-wrap helper exists and is executable" {
    [[ -x "$DOTFILES_DIR/bin/lspmux-wrap" ]]
}

@test "shadow wrappers exist for all 7 LSPs" {
    local wrappers=(
        pyright-langserver
        gopls
        rust-analyzer
        vtsls
        solargraph
        bash-language-server
        yaml-language-server
    )
    for w in "${wrappers[@]}"; do
        [[ -x "$DOTFILES_DIR/bin/$w" ]] || {
            echo "missing or not executable: bin/$w" >&2
            return 1
        }
    done
}

@test "shadow wrappers are found before real binaries on PATH" {
    # Simulate the zsh PATH order: dotfiles/bin must be before pyenv shims
    local test_path="$DOTFILES_DIR/bin:$PATH"
    local wrap_path
    wrap_path="$(PATH="$test_path" command -v pyright-langserver 2>/dev/null || true)"
    if [[ -n "$wrap_path" ]]; then
        [[ "$wrap_path" == "$DOTFILES_DIR/bin/pyright-langserver" ]]
    else
        skip "pyright-langserver not on PATH"
    fi
}

# ===========================================================================
# SECTION 2 — launchd plist
# ===========================================================================

@test "launchd plist exists in LaunchAgents" {
    [[ -f "$HOME/Library/LaunchAgents/com.lspmux.server.plist" ]]
}

@test "launchd plist is valid XML" {
    run plutil -lint "$HOME/Library/LaunchAgents/com.lspmux.server.plist"
    [[ "$status" -eq 0 ]]
}

@test "launchd plist has no unexpanded template placeholders" {
    ! grep -q '{{' "$HOME/Library/LaunchAgents/com.lspmux.server.plist"
}

@test "launchd plist points to existing lspmux binary" {
    local bin_path
    bin_path="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$HOME/Library/LaunchAgents/com.lspmux.server.plist")"
    [[ -x "$bin_path" ]]
}

# ===========================================================================
# SECTION 3 — config
# ===========================================================================

@test "lspmux config exists at macOS Application Support path" {
    [[ -f "$HOME/Library/Application Support/lspmux/config.toml" ]]
}

@test "lspmux config contains expected keys" {
    local config="$HOME/Library/Application Support/lspmux/config.toml"
    grep -q 'instance_timeout' "$config"
    grep -q 'listen' "$config"
    grep -q 'connect' "$config"
}

# ===========================================================================
# SECTION 4 — server status (skip if not running)
# ===========================================================================

@test "launchd service is registered" {
    run launchctl print "gui/$(id -u)/com.lspmux.server"
    [[ "$status" -eq 0 ]]
}

@test "lspmux server is reachable" {
    # lspmux status connects to the server; exit 0 = reachable
    run lspmux status
    [[ "$status" -eq 0 ]]
}
