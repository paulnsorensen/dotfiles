#!/usr/bin/env bats
# Validate config files for Rust CLI tools and other managed configs
# Catches breakage from version upgrades (e.g., a starship schema change)

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

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
    local config="$DOTFILES_DIR/chezmoi/dot_config/atuin/config.toml"
    [[ -f "$config" ]] || skip "atuin config not found"
    # yq can validate TOML
    run yq '.' "$config" -p toml -o json
    [[ $status -eq 0 ]]
}

# ── Yazi ──────────────────────────────────────────────────────────────────────

@test "yazi config is valid TOML" {
    local config="$DOTFILES_DIR/chezmoi/dot_config/yazi/yazi.toml"
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
    local registry="$DOTFILES_DIR/agents/mcp/registry.yaml"
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
    run yq '.' "$DOTFILES_DIR/packages/packages.yaml"
    [[ $status -eq 0 ]]
}

@test "packages.yaml map entries have exactly one key (the name)" {
    local bad
    bad=$(yq -r '.packages[] | select(kind == "map") | select((keys | length) == 1 | not)' "$DOTFILES_DIR/packages/packages.yaml" 2>/dev/null)
    [[ -z "$bad" ]]
}

# ── skill-* aliases (unified ap deploy — curd 7) ──────────────────────────────
# The registry stays the EDIT surface (skill-edit); deploy is unified through
# `ap` (skill-sync → base-sync → `dots profile install base`). Locking the bodies guards a
# silent de-sync where a rename would only surface at every dev's runtime.

@test "skill-sync alias deploys via the unified ap base-profile render" {
    local aliases_file="$DOTFILES_DIR/zsh/aliases.zsh"
    grep -qE "^alias skill-sync='base-sync'" "$aliases_file"
    grep -qE "^alias skill-edit='\\\$\\{EDITOR:-vim\\} \\\$DOTFILES_DIR/skills/_registry\\.yaml'" "$aliases_file"
}

@test "skill-* alias targets resolve to real artifacts (ap shim + registry)" {
    [[ -x "$DOTFILES_DIR/agent-profile/ap" ]]
    [[ -f "$DOTFILES_DIR/skills/_registry.yaml" ]]
}

@test "base-sync pins --target \$HOME and mirrors the two-target render (curd 7 alias --target fix)" {
    local claude_file="$DOTFILES_DIR/zsh/claude.zsh"
    # High age finding: a bare `dots profile install base` defaults --target to
    # \$PWD, silently deploying to the cwd. The deploy verb must pin \$HOME and
    # mirror install-base-profile.sh's two-target asymmetry.
    # shellcheck disable=SC2016  # match the literal $HOME in the alias body, not expand it
    grep -qE 'dots profile install base --target "\$HOME"' "$claude_file"
    # shellcheck disable=SC2016
    grep -qE 'dots profile install base --target "\$HOME/\.config/opencode"' "$claude_file"
    grep -qE -- '--harness opencode' "$claude_file"
}

@test "mcp-sync / hook-sync / skill-sync route through base-sync (no bare cwd install)" {
    grep -qE "^alias mcp-sync='base-sync'" "$DOTFILES_DIR/zsh/claude.zsh"
    grep -qE "^alias hook-sync='base-sync'" "$DOTFILES_DIR/zsh/claude.zsh"
    grep -qE "^alias skill-sync='base-sync'" "$DOTFILES_DIR/zsh/aliases.zsh"
}

@test "skill-* aliases do not reference the pre-flatten skills-install/ or claude/skills paths" {
    local aliases_file="$DOTFILES_DIR/zsh/aliases.zsh"
    # Inspect only the alias bodies. The surrounding comment block legitimately
    # describes the new layout; we only want to fail if a *definition* drifts.
    run grep -E "^alias skill-" "$aliases_file"
    [[ $status -eq 0 ]]
    if echo "$output" | grep -qE 'skills-install/|claude/skills'; then
        echo "skill-* alias body still references pre-flatten paths:" >&2
        echo "$output" >&2
        return 1
    fi
}
