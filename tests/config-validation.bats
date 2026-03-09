#!/usr/bin/env bats
# Validate config files for Rust CLI tools and other managed configs
# Catches breakage from version upgrades (e.g., zellij 0.43 removing NewFloatingPane)

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# ── Zellij ────────────────────────────────────────────────────────────────────

@test "zellij config.kdl parses without errors" {
    command -v zellij &>/dev/null || skip "zellij not installed"
    run zellij setup --check
    [[ $status -eq 0 ]]
}

@test "zellij config.kdl exists" {
    [[ -f "$DOTFILES_DIR/zellij/config.kdl" ]]
}

@test "zellij layouts parse correctly" {
    command -v zellij &>/dev/null || skip "zellij not installed"

    # Use a temp zellij config dir to avoid corrupting real config (hard links!)
    local tmp_config="$BATS_TMPDIR/zellij-test-$$"
    mkdir -p "$tmp_config/layouts"
    cp "$HOME/.config/zellij/config.kdl" "$tmp_config/config.kdl"

    local failed=0
    for layout in "$DOTFILES_DIR"/zellij/layouts/*.kdl; do
        [[ -f "$layout" ]] || continue
        cp "$layout" "$tmp_config/layouts/default.kdl"
        if ! XDG_CONFIG_HOME="$tmp_config/.." zellij setup --check &>/dev/null; then
            echo "Layout failed validation: $(basename "$layout")" >&2
            failed=1
        fi
    done
    rm -rf "$tmp_config"
    [[ $failed -eq 0 ]]
}

@test "zjclaude generated layout is valid KDL" {
    command -v zellij &>/dev/null || skip "zellij not installed"

    # Use a temp zellij config dir (never touch real config)
    local tmp_config="$BATS_TMPDIR/zellij-zjclaude-$$"
    mkdir -p "$tmp_config/layouts"
    cp "$HOME/.config/zellij/config.kdl" "$tmp_config/config.kdl"

    # Generate the layout exactly as zjclaude would
    cat > "$tmp_config/layouts/default.kdl" <<LAYOUT
layout {
    pane size=1 borderless=true {
        plugin location="zellij:compact-bar"
    }
    pane focus=true cwd="$PWD" {
        command "claude"
    }
    pane size=2 borderless=true name="monitor" cwd="$PWD" {
        command "claude-monitor"
        args "--cwd" "$PWD"
    }
}
LAYOUT

    run bash -c "XDG_CONFIG_HOME='$tmp_config/..' zellij setup --check"
    rm -rf "$tmp_config"
    [[ $status -eq 0 ]]
}

# ── Starship ──────────────────────────────────────────────────────────────────

@test "starship config is valid TOML" {
    command -v starship &>/dev/null || skip "starship not installed"
    local config="$DOTFILES_DIR/starship/starship.toml"
    [[ -f "$config" ]]
    # print-config parses and validates the config without opening an editor
    run env STARSHIP_CONFIG="$config" starship print-config
    [[ $status -eq 0 ]]
}

@test "starship schema reference is present" {
    local config="$DOTFILES_DIR/starship/starship.toml"
    [[ -f "$config" ]] || skip "starship config not found"
    # shellcheck disable=SC2016  # $schema is a literal TOML key, not a variable
    grep -q '"$schema"' "$config"
}

# ── Atuin ─────────────────────────────────────────────────────────────────────

@test "atuin config is valid TOML" {
    local config="$DOTFILES_DIR/atuin/config.toml"
    [[ -f "$config" ]] || skip "atuin config not found"
    # yq can validate TOML
    run yq '.' "$config" -p toml -o json
    [[ $status -eq 0 ]]
}

# ── Yazi ──────────────────────────────────────────────────────────────────────

@test "yazi config is valid TOML" {
    local config="$DOTFILES_DIR/yazi/yazi.toml"
    [[ -f "$config" ]] || skip "yazi config not found"
    run yq '.' "$config" -p toml -o json
    [[ $status -eq 0 ]]
}

# ── Shell scripts ─────────────────────────────────────────────────────────────

@test "all zsh config files have valid syntax" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    local failed=0
    for f in "$DOTFILES_DIR"/zsh/*.zsh; do
        if ! zsh -n "$f" 2>/dev/null; then
            echo "Syntax error in: $(basename "$f")" >&2
            failed=1
        fi
    done
    [[ $failed -eq 0 ]]
}

@test "zshrc has valid syntax" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    run zsh -n "$DOTFILES_DIR/zshrc"
    [[ $status -eq 0 ]]
}

@test "all bash scripts pass shellcheck" {
    command -v shellcheck &>/dev/null || skip "shellcheck not installed"
    local failed=0
    for f in "$DOTFILES_DIR"/bin/*; do
        [[ -f "$f" ]] || continue
        # Only check bash scripts (not zsh or other)
        head -1 "$f" | grep -q "bash" || continue
        if ! shellcheck -S warning "$f" 2>/dev/null; then
            echo "shellcheck warnings in: $(basename "$f")" >&2
            failed=1
        fi
    done
    [[ $failed -eq 0 ]]
}

# ── MCP & Plugin sync scripts ────────────────────────────────────────────────

@test "MCP registry is valid YAML" {
    local registry="$DOTFILES_DIR/claude/mcp/registry.yaml"
    [[ -f "$registry" ]] || skip "MCP registry not found"
    run yq '.' "$registry"
    [[ $status -eq 0 ]]
}

@test "plugin registry is valid YAML" {
    local registry="$DOTFILES_DIR/claude/plugins/registry.yaml"
    [[ -f "$registry" ]] || skip "plugin registry not found"
    run yq '.' "$registry"
    [[ $status -eq 0 ]]
}

@test "packages.yaml is valid YAML" {
    run yq '.' "$DOTFILES_DIR/packages.yaml"
    [[ $status -eq 0 ]]
}
