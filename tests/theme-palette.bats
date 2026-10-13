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
    cp "$REAL_DOTFILES_DIR/theme/lib-zed.sh" "$THEME_REPO/theme/lib-zed.sh"
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
    grep -qx 'set -g @thm_surface_0   "#261f1b"' "$conf"
    grep -qx 'set -g @thm_fg          "#e6dcd6"' "$conf"

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
    [ "$(jq -r '.name' "$theme_file")" = "Brownfield" ]
    [ "$(jq -r '.themes[0].appearance' "$theme_file")" = "dark" ]
    [ "$(jq -r '.themes[0].style.background' "$theme_file")" = "#211a16" ]
    [ "$(jq -r '.themes[0].style["terminal.ansi.red"]' "$theme_file")" = "#b69599" ]
    # Bright row: the one non-obvious mapping — bright_yellow comes from base09.
    [ "$(jq -r '.themes[0].style["terminal.ansi.bright_yellow"]' "$theme_file")" = "#ff7643" ]
    # Contract syntax colors (mirror the vimrc highlight mapping).
    [ "$(jq -r '.themes[0].style.syntax.comment.color' "$theme_file")" = "#8b8b8b" ]
    [ "$(jq -r '.themes[0].style.syntax.string.color' "$theme_file")" = "#a1cb2d" ]
    [ "$(jq -r '.themes[0].style.syntax.keyword.color' "$theme_file")" = "#d36bd1" ]
    [ "$(jq -r '.themes[0].style.syntax.function.color' "$theme_file")" = "#799af9" ]
    [ "$(jq -r '.themes[0].style.syntax.type.color' "$theme_file")" = "#f5d710" ]
    [ "$(jq -r '.themes[0].style.syntax.number.color' "$theme_file")" = "#ff7643" ]
    # The shared tree and chat panels differ from the code canvas.
    jq -e '.themes[0].style as $s |
      $s["editor.background"] == "#211a16" and
      $s["editor.gutter.background"] == "#211a16" and
      $s["terminal.background"] == "#211a16" and
      $s["surface.background"] == "#322b26" and
      $s["panel.background"] == "#322b26" and
      $s["elevated_surface.background"] == "#3c322b" and
      $s.border == "#8b8b8b" and
      $s["border.variant"] == "#8b8b8b" and
      $s["text.placeholder"] == "#b7b2b0" and
      $s["text.disabled"] == "#b7b2b0"' "$theme_file"
    jq -e '.themes[0].style as $s |
      $s["text.accent"] == "#799af9" and
      $s["icon.accent"] == "#799af9" and
      $s["editor.active_line_number"] == "#799af9" and
      $s["border.focused"] == "#799af9" and
      $s["panel.focused_border"] == "#799af9" and
      $s["pane.focused_border"] == "#799af9" and
      $s.modified == "#799af9" and
      $s.warning == "#f5d710" and
      $s.syntax.type.color == "#f5d710" and
      $s["terminal.ansi.yellow"] == "#f5d710"' "$theme_file"
    python3 - "$theme_file" <<'PY'
import json
import sys

style = json.load(open(sys.argv[1]))["themes"][0]["style"]

def luminance(color):
    values = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    channels = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values]
    return sum(weight * channel for weight, channel in zip((0.2126, 0.7152, 0.0722), channels))

for background in ("panel.background", "elevated_surface.background"):
    for foreground in ("text.placeholder", "text.disabled"):
        values = sorted((luminance(style[background]), luminance(style[foreground])))
        assert (values[1] + 0.05) / (values[0] + 0.05) >= 4.5, (background, foreground)
PY
    # Players render like Zed's shipped themes: background = cursor accent,
    # selection = that accent at ~24% alpha (3d suffix).
    [ "$(jq -r '.themes[0].style.players[0].background' "$theme_file")" = "$(jq -r '.themes[0].style.players[0].cursor' "$theme_file")" ]
    [ "$(jq -r '.themes[0].style.players[0].cursor' "$theme_file")" = "#799af9" ]
    [[ "$(jq -r '.themes[0].style.players[0].selection' "$theme_file")" == \#799af93d ]]
}

@test "generate_zed_theme also writes the inactive chocolate-donut-2 theme" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run bash "$THEME_REPO/theme/generate.sh"
    assert_success

    local active_file="$THEME_REPO/chezmoi/dot_config/zed/themes/dotfiles-theme.json"
    local theme_file="$THEME_REPO/chezmoi/dot_config/zed/themes/chocolate-donut-2.json"
    assert_file_exists "$theme_file"

    jq empty "$theme_file"
    [ "$(jq -r '.themes[0].name' "$theme_file")" = "Chocolate Donut 2" ]
    [ "$(jq -r '.themes[0].style.background' "$theme_file")" = "#221d1a" ]
    [ "$(jq -r '.themes[0].style.syntax.keyword.color' "$theme_file")" = "#e47be2" ]
    [ "$(jq -r '.themes[0].style["terminal.ansi.bright_yellow"]' "$theme_file")" = "#f6cfa0" ]
    jq -e '.themes[0].style as $s | $s["panel.background"] == "#27221f" and $s["elevated_surface.background"] == "#27221f" and $s.border == "#2c2723" and $s["text.placeholder"] == "#8e8e8e"' "$theme_file"
    jq -e '.themes[0].style as $s |
      $s["editor.active_line_number"] == "#d7aa26" and
      ($s | has("text.accent") | not) and
      ($s | has("icon.accent") | not) and
      ($s | has("border.focused") | not) and
      ($s | has("panel.focused_border") | not) and
      ($s | has("pane.focused_border") | not) and
      ($s | has("modified") | not)' "$theme_file"
    # The extra scheme must not leak into the active theme or later targets.
    [ "$(jq -r '.themes[0].name' "$active_file")" = "Brownfield" ]
    grep -qx 'set -g @thm_fg          "#e6dcd6"' "$THEME_REPO/tmux/theme.conf"
}
