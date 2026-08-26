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
    grep -qx 'set -g @thm_surface_0   "#312b27"' "$conf"
    grep -qx 'set -g @thm_fg          "#dac2b1"' "$conf"

    # Old mismatched names must be gone — their presence is exactly the bug:
    # `-ogq @thm_surface0` / `-ogq @thm_text` never matches our `@thm_surface0`
    # / `@thm_text` override, so mocha's default silently wins.
    ! grep -q '@thm_surface0\b' "$conf"
    ! grep -q '@thm_text\b' "$conf"
}

@test "generate_zed_theme writes a valid Zed user theme from the base24 scheme" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run bash "$THEME_REPO/theme/generate.sh"
    assert_success

    local theme_file="$THEME_REPO/chezmoi/dot_config/zed/themes/dotfiles-theme.json"
    assert_file_exists "$theme_file"

    jq empty "$theme_file"
    [ "$(jq -r '.name' "$theme_file")" = "Chocolate Donut" ]
    [ "$(jq -r '.themes[0].appearance' "$theme_file")" = "dark" ]
    [ "$(jq -r '.themes[0].style.background' "$theme_file")" = "#221d1a" ]
    [ "$(jq -r '.themes[0].style["terminal.ansi.red"]' "$theme_file")" = "#eb6b6f" ]
    # Bright row: the one non-obvious mapping — bright_yellow comes from base09.
    [ "$(jq -r '.themes[0].style["terminal.ansi.bright_yellow"]' "$theme_file")" = "#e9b76b" ]
    # Contract syntax colors (mirror the vimrc highlight mapping).
    [ "$(jq -r '.themes[0].style.syntax.comment.color' "$theme_file")" = "#939393" ]
    [ "$(jq -r '.themes[0].style.syntax.string.color' "$theme_file")" = "#88b994" ]
    [ "$(jq -r '.themes[0].style.syntax.keyword.color' "$theme_file")" = "#b287cd" ]
    [ "$(jq -r '.themes[0].style.syntax.function.color' "$theme_file")" = "#8196a8" ]
    [ "$(jq -r '.themes[0].style.syntax.type.color' "$theme_file")" = "#ffae00" ]
    [ "$(jq -r '.themes[0].style.syntax.number.color' "$theme_file")" = "#e9b76b" ]
    # Players render like Zed's shipped themes: background = cursor accent,
    # selection = that accent at ~24% alpha (3d suffix).
    [ "$(jq -r '.themes[0].style.players[0].background' "$theme_file")" = "$(jq -r '.themes[0].style.players[0].cursor' "$theme_file")" ]
    [ "$(jq -r '.themes[0].style.players[0].cursor' "$theme_file")" = "#8196a8" ]
    [[ "$(jq -r '.themes[0].style.players[0].selection' "$theme_file")" == \#8196a83d ]]
}
