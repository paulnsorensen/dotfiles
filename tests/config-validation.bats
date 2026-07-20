#!/usr/bin/env bats
# shellcheck disable=SC2016
# Validate config files for Rust CLI tools and other managed configs

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

# ── Milknado ─────────────────────────────────────────────────────────────────

@test "milknado config pins the repository verification gate" {
    local config="$DOTFILES_DIR/milknado.toml"
    [[ -f "$config" ]]
    run yq -p=toml -o=json '.' "$config"
    [[ $status -eq 0 ]]
    [[ "$(yq -p=toml '.milknado.quality_gates | join(",")' "$config")" == "just check" ]]
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

# ── Codex ───────────────────────────────────────────────────────────────────

@test "codex config seed is valid TOML" {
    local config="$DOTFILES_DIR/codex/config.toml"
    [[ -f "$config" ]] || skip "codex config seed not found"
    run yq '.' "$config" -p toml -o json
    [[ $status -eq 0 ]]
}

@test "codex config seed registers tilth in edit mode (--edit)" {
    # Reproducibility guard: the agents/mcp sync that once populated
    # ~/.codex/config.toml is retired, so this seed is the only source of tilth
    # on a fresh setup. Without --edit tilth is read-only and cheez-write breaks.
    local config="$DOTFILES_DIR/codex/config.toml"
    [[ -f "$config" ]] || skip "codex config seed not found"
    [[ "$(yq -p=toml '.mcp_servers.tilth.command' "$config")" == "tilth" ]]
    yq -p=toml '.mcp_servers.tilth.args[]' "$config" | grep -qx -- '--edit'
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

@test "hallouminate plugin reaches every supported harness" {
    local registry="$DOTFILES_DIR/agents/plugins/registry.yaml"
    [[ -f "$registry" ]] || skip "cross-harness plugin registry not found"

    run yq -r '.plugins.hallouminate.harnesses | sort | join(",")' "$registry"
    [[ $status -eq 0 ]]
    [[ "$output" == "claude,codex,copilot,crush,cursor,opencode" ]]
    [[ "$(yq -r '.plugins.hallouminate.native' "$registry")" == "true" ]]
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

# ── skill-* aliases (unified live deploy) ────────────────────────────────────
# The registry stays the EDIT surface (skill-edit); deploy is unified through
# `dots sync` (chezmoi-authoritative source assembly). The redundant
# per-registry *-sync mnemonics — and later base-sync itself — were retired.
# Locking the bodies guards a silent de-sync where a rename would only surface
# at every dev's runtime.

@test "skill-edit opens the external skills registry (the edit surface)" {
    local aliases_file="$DOTFILES_DIR/zsh/aliases.zsh"
    grep -qE "^alias skill-edit='\\\$\\{EDITOR:-vim\\} \\\$DOTFILES_DIR/skills/_registry\\.yaml'" "$aliases_file"
}

@test "skill-* alias targets resolve to real artifacts (ap shim + registry)" {
    [[ -x "$DOTFILES_DIR/agent-profile/ap" ]]
    [[ -f "$DOTFILES_DIR/skills/_registry.yaml" ]]
}

@test "dots sync ignores the retired --accept-agent-drift flag (compat shim)" {
    local shim="$BATS_TEST_TMPDIR/dots-home"
    mkdir -p "$shim/Dev/dotfiles"
    run env DOTFILES_DIR="$shim/Dev/dotfiles" bash -c '
        cp "$1/bin/dots" "$DOTFILES_DIR/dots"
        cat > "$DOTFILES_DIR/.sync" <<'"'"'SH'"'"'
#!/usr/bin/env bash
printf "DOTS_ACCEPT_AGENT_DRIFT=%s args=%s\n" "${DOTS_ACCEPT_AGENT_DRIFT:-}" "$*"
SH
        chmod +x "$DOTFILES_DIR/.sync"
        "$DOTFILES_DIR/dots" sync --accept-agent-drift refresh
    ' _ "$DOTFILES_DIR"
    [[ $status -eq 0 ]]
    # Flag swallowed with a retirement warning; env var no longer set.
    [[ "$output" == *"DOTS_ACCEPT_AGENT_DRIFT= args=refresh"* ]]
    [[ "$output" == *"retired"* ]]
}

@test "base-sync is retired from zsh/claude.zsh (chezmoi owns claude deploys)" {
    local claude_file="$DOTFILES_DIR/zsh/claude.zsh"
    # No function or alias may resurrect the ap live-install entry point.
    if grep -qE '^base-sync\(\)|alias base-sync=' "$claude_file"; then
        echo "base-sync still defined in zsh/claude.zsh" >&2
        return 1
    fi
    # mcp-edit now points at the claude registry.
    grep -qF 'chezmoi/.chezmoidata/claude.yaml' "$claude_file"
}

@test "the redundant *-sync mnemonics are retired (base-sync is the sole entry point)" {
    # mcp-sync / hook-sync / agent-sync / skill-sync collapsed into base-sync.
    # Guard against them silently returning as bare-cwd-install footholds.
    ! grep -qE "^alias (mcp|hook|agent)-sync=" "$DOTFILES_DIR/zsh/claude.zsh"
    ! grep -qE "^alias skill-sync=" "$DOTFILES_DIR/zsh/aliases.zsh"
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
