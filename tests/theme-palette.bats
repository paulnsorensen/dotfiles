#!/usr/bin/env bats
# Regression for theme/generate.sh emitting @thm_* option names that match
# catppuccin/tmux v2's declarations. The plugin loads overrides with
# `set -ogq @thm_<name> "..."` — `-ogq` only preserves a pre-set value under
# the EXACT option name, so a mismatched name is silently invisible and the
# built-in mocha default wins instead. See catppuccin_options_tmux.conf for
# the option names the plugin actually declares (@thm_fg, @thm_surface_0/1/2,
# @thm_subtext_0/1, @thm_overlay_0/1/2).

load test_helper

setup() {
    setup_test_env
    export THEME_REPO="$TEST_HOME/theme-repo"
    mkdir -p "$THEME_REPO/theme" "$THEME_REPO/zsh" "$THEME_REPO/bin"
    touch "$THEME_REPO/vimrc"
    cp "$REAL_DOTFILES_DIR/theme/generate.sh" "$THEME_REPO/theme/generate.sh"
    cp "$REAL_DOTFILES_DIR/theme/config.yaml" "$THEME_REPO/theme/config.yaml"
    cp -R "$REAL_DOTFILES_DIR/theme/schemes" "$THEME_REPO/theme/schemes"
}

teardown() { teardown_test_env; }

@test "generate_tmux_theme emits catppuccin/tmux v2's exact @thm_* option names" {
    run bash "$THEME_REPO/theme/generate.sh"
    assert_success

    local conf="$THEME_REPO/tmux/theme.conf"
    assert_file_exists "$conf"

    # Correct names catppuccin/tmux v2 declares via `-ogq` — must be present
    # verbatim or the plugin's exact-name match never sees our override.
    grep -qx 'set -g @thm_surface_0   "#3c291c"' "$conf"
    grep -qx 'set -g @thm_fg          "#dac2b1"' "$conf"

    # Old mismatched names must be gone — their presence is exactly the bug:
    # `-ogq @thm_surface0` / `-ogq @thm_text` never matches our `@thm_surface0`
    # / `@thm_text` override, so mocha's default silently wins.
    ! grep -q '@thm_surface0\b' "$conf"
    ! grep -q '@thm_text\b' "$conf"
}
