#!/usr/bin/env bats
# Behavioural tests for chezmoi/dot_config/zed/settings.json.tmpl and
# chezmoi/dot_config/zed/keymap.json. settings.json.tmpl is rendered with
# `chezmoi execute-template`; both files use full-line `//` comments that
# must be stripped before jq can parse the JSONC content.

load test_helper

setup() {
    setup_test_env
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
}

teardown() { teardown_test_env; }

strip_comments() {
    grep -v '^\s*//' "$1"
}

@test "zed-settings: renders with vim, fonts, format-on-save on, LSP, MCP context servers, and agent_servers registry entries" {
    local cfg="$TEST_HOME/cz.toml"
    cat > "$cfg" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
TOML
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/dot_config/zed/settings.json.tmpl"
    run chezmoi --config "$cfg" --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl"
    [ "$status" -eq 0 ]

    local rendered="$TEST_HOME/settings.json"
    printf '%s' "$output" > "$rendered"
    ! grep -qF '{{' "$rendered"

    local stripped="$TEST_HOME/settings.stripped.json"
    strip_comments "$rendered" > "$stripped"

    jq empty "$stripped"
    [ "$(jq -r '.vim_mode' "$stripped")" = "true" ]
    [ "$(jq -r '.buffer_font_family' "$stripped")" = "JetBrainsMono Nerd Font" ]
    [ "$(jq -r '.agent_servers | has("codex-acp")' "$stripped")" = "true" ]
    [ "$(jq -r '.agent_servers | has("Codex")' "$stripped")" = "true" ]
    [ "$(jq -r '.agent_servers | has("OMP")' "$stripped")" = "true" ]
    [ "$(jq -r '.agent_servers | has("claude-acp")' "$stripped")" = "true" ]
    [ "$(jq -r '.agent_servers["claude-acp"].type' "$stripped")" = "registry" ]
    [ "$(jq -r '.format_on_save' "$stripped")" = "on" ]
    [ "$(jq -r '.formatter' "$stripped")" = "language_server" ]
    # Telemetry opt-out folded in from live drift.
    [ "$(jq -r '.telemetry.metrics' "$stripped")" = "false" ]
    [ "$(jq -r '.telemetry.anthropic_retention' "$stripped")" = "false" ]
    # Built-in LSP: per-language formatting, ruff for Python, clippy for Rust; shell/markdown opt out.
    [ "$(jq -r '.languages.Python.formatter.external.command' "$stripped")" = "ruff" ]
    [ "$(jq -r '.languages.Rust.format_on_save' "$stripped")" = "on" ]
    [ "$(jq -r '.languages["Shell Script"].format_on_save' "$stripped")" = "off" ]
    [ "$(jq -r '.languages.Markdown.format_on_save' "$stripped")" = "off" ]
    [ "$(jq -r '.lsp["rust-analyzer"].initialization_options.check.command' "$stripped")" = "clippy" ]
    # MCP context servers wire the full roster to Zed's native Agent Panel.
    [ "$(jq -r '.context_servers | has("tilth")' "$stripped")" = "true" ]
    [ "$(jq -r '.context_servers | has("hallouminate")' "$stripped")" = "true" ]
    [ "$(jq -r '.context_servers | has("milknado")' "$stripped")" = "true" ]
    [ "$(jq -r '.context_servers.tilth.source' "$stripped")" = "custom" ]
    # Secret-bearing servers reuse the shared broker sockets — empty env, no envFile.
    [ "$(jq -r '.context_servers.context7.command' "$stripped")" = "/usr/local/libexec/dotfiles/agent-secret-proxy" ]
    [ "$(jq -c '.context_servers.tavily.args' "$stripped")" = '["--socket","/var/run/dotfiles-agent-secrets/tavily.sock"]' ]
    [ "$(jq -c '.context_servers.context7.env' "$stripped")" = '{}' ]
    [ "$(jq -r '.context_servers.tavily | has("envFile")' "$stripped")" = "false" ]
    # OMP ACP model pin preserved (folded from live drift).
    [ "$(jq -r '.agent_servers.OMP.default_config_options.model' "$stripped")" = "openai-codex/gpt-5.6-sol" ]
    [ "$(jq -r '.project_panel.dock' "$stripped")" = "left" ]
    [ "$(jq -r '.relative_line_numbers' "$stripped")" = "enabled" ]
    [ "$(jq -r '.vertical_scroll_margin' "$stripped")" = "5" ]
    [ "$(jq -r '.tab_size' "$stripped")" = "2" ]
    [ "$(jq -r '.hard_tabs' "$stripped")" = "false" ]
    [ "$(jq -r '.soft_wrap' "$stripped")" = "none" ]
    [ "$(jq -c '.buffer_font_fallbacks' "$stripped")" = '["Hack Nerd Font Mono"]' ]
    [ "$(jq -r '.buffer_font_size' "$stripped")" = "14" ]
    [ "$(jq -r '.ensure_final_newline_on_save' "$stripped")" = "true" ]
    [ "$(jq -r '.remove_trailing_whitespace_on_save' "$stripped")" = "true" ]
    [ "$(jq -r '.vim.use_system_clipboard' "$stripped")" = "always" ]
    [ "$(jq -r '.vim.use_smartcase_find' "$stripped")" = "true" ]
    [ "$(jq -r '.vim.toggle_relative_line_numbers' "$stripped")" = "true" ]
    [ "$(jq -r '.terminal.font_family' "$stripped")" = "JetBrainsMono Nerd Font" ]
    [ "$(jq -r '.terminal.font_size' "$stripped")" = "14" ]
}

@test "zed-keymap: parses after comment-strip and toggles the bottom dock" {
    local keymap="$REAL_DOTFILES_DIR/chezmoi/dot_config/zed/keymap.json"
    local stripped="$TEST_HOME/keymap.stripped.json"
    strip_comments "$keymap" > "$stripped"

    jq empty "$stripped"
    grep -qF 'workspace::ToggleBottomDock' "$stripped"
}
