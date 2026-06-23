#!/usr/bin/env bats
# Validate config files for Rust CLI tools and other managed configs

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

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
# `base-sync` (→ `dots profile install base`). The redundant per-registry
# *-sync mnemonics were retired in favour of the single base-sync entry point.
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

@test "base-sync dispatches the live wrapper profiles (curd 7 manual deploy parity)" {
    local claude_file="$DOTFILES_DIR/zsh/claude.zsh"
    command -v zsh &>/dev/null || skip "zsh not installed"
    local harness="$BATS_TEST_TMPDIR/base-sync.zsh"
    cat > "$harness" <<EOF
#!/usr/bin/env zsh
dots() { print -r -- "\$@"; }
$(sed -n '/^base-sync()/,/^}/p' "$claude_file")
base-sync
EOF
    run zsh "$harness"
    [[ $status -eq 0 ]]
    [[ "$output" == *"profile install global --harness claude,codex,cursor,copilot"* ]]
    [[ "$output" == *"profile install opencode-global --harness opencode"* ]]
    [[ "$output" != *"--target"* ]]
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
