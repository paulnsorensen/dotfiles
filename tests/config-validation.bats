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

@test "codex registry is valid YAML with the required top-level keys" {
    # Replaces the retired codex/config.toml seed: ~/.codex/config.toml is now
    # merged from this registry by chezmoi/private_dot_codex/modify_private_config.toml.
    local reg="$DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml"
    [[ -f "$reg" ]]
    run yq -e '.' "$reg"
    [[ $status -eq 0 ]]
    [[ "$(yq -oy -r '.codex.config.model' "$reg")" != "null" ]]
    [[ "$(yq -oy -r '.codex.mcps | length' "$reg")" -gt 0 ]]
    [[ "$(yq -oy -r '.codex.agents | length' "$reg")" -gt 0 ]]
}

@test "managed tilth MCPs expose search v2 alongside v1 in edit mode" {
    local expected='["--mcp","--edit","--search-surface","both"]'
    local entry path query actual rendered profile

    for entry in \
        "$DOTFILES_DIR/chezmoi/.chezmoidata/claude.yaml:.claude.mcps.tilth.args" \
        "$DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml:.codex.mcps.tilth.args" \
        "$DOTFILES_DIR/agents/mcp/registry.yaml:.mcps.tilth.args"; do
        path=${entry%%:*}
        query=${entry#*:}
        actual=$(yq -I=0 -o=json "$query" "$path")
        [[ "$actual" == "$expected" ]] || {
            echo "$path: expected $expected, got $actual" >&2
            return 1
        }
    done

    path="$DOTFILES_DIR/chezmoi/dot_omp/private_agent/mcp.json"
    actual=$(jq -c '.mcpServers.tilth.args' "$path")
    [[ "$actual" == "$expected" ]] || {
        echo "$path: expected $expected, got $actual" >&2
        return 1
    }

    path="$DOTFILES_DIR/chezmoi/private_dot_copilot/mcp-config.json.tmpl"
    rendered=$(chezmoi execute-template < "$path")
    actual=$(jq -c '.mcpServers.tilth.args' <<< "$rendered")
    [[ "$actual" == "$expected" ]] || {
        echo "$path: expected $expected, got $actual" >&2
        return 1
    }

    for profile in "$DOTFILES_DIR"/profiles/{codex-code,codex-plan,fe,oss-docs,plugin,review,rtkonly,skills-doctor,spec}/profile.yaml; do
        actual=$(yq -I=0 -o=json '.mcps[] | select(.name == "tilth") | .args' "$profile")
        [[ "$actual" == "$expected" ]] || {
            echo "$profile: expected $expected, got $actual" >&2
            return 1
        }
    done
}

@test "codex registry declares no env block (secrets stay out of config.toml)" {
    # Codex is terminal-launched and its MCP children inherit the exported shell
    # env, so neither a secret nor a ${VAR} placeholder may be written to disk.
    # See .hallouminate/wiki/architecture/mcp-secret-handling.md.
    local reg="$DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml"
    [[ "$(yq -oy -r '[.codex.mcps[] | select(has("env"))] | length' "$reg")" == "0" ]]
}

@test "codex registry only selects agents that declare the codex harness" {
    local reg="$DOTFILES_DIR/chezmoi/.chezmoidata/codex.yaml"
    local agents="$DOTFILES_DIR/agents/registry.yaml"
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        run yq -oy -r ".agents.\"$name\" | [((.harnesses // [\"claude\",\"codex\"])[]) == \"codex\"] | any" "$agents"
        [[ "$output" == "true" ]] || {
            echo "codex.yaml selects $name, which does not declare the codex harness" >&2
            return 1
        }
    done < <(yq -oy -r '.codex.agents[]' "$reg")
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
    [[ "$output" == "claude,codex,copilot,cursor" ]]
    [[ "$(yq -r '.plugins.hallouminate.native' "$registry")" == "true" ]]
}

@test "AC-7 plugin skill sources ship to the shared dir only on non-native harnesses" {
    local skills_reg="$DOTFILES_DIR/skills/_registry.yaml"
    local plugin_reg="$DOTFILES_DIR/agents/plugins/registry.yaml"
    local shared="codex copilot zed omp"
    local plugin name skills_path harnesses native_raw native_set expected

    for plugin in milknado hallouminate; do
        name="paulnsorensen/$plugin"
        run yq -e ".sources.\"$name\"" "$skills_reg"
        [[ $status -eq 0 ]] || { echo "$plugin: source $name missing" >&2; return 1; }

        skills_path=$(yq -r ".sources.\"$name\".skills_path // \"\"" "$skills_reg")
        [[ "$skills_path" == "plugins/$plugin/skills" ]]

        harnesses=$(yq -r ".sources.\"$name\".harnesses // [] | sort | join(\" \")" "$skills_reg")
        [[ -n "$harnesses" ]]

        native_raw=$(yq -r ".plugins.\"$plugin\".native // false" "$plugin_reg")
        if [[ "$native_raw" == "true" ]]; then
            native_set=$(yq -r ".plugins.\"$plugin\".harnesses // [] | map(select(. == \"claude\" or . == \"codex\" or . == \"copilot\")) | join(\" \")" "$plugin_reg")
        elif [[ "$native_raw" == "false" ]]; then
            native_set=""
        else
            native_set=$(yq -r ".plugins.\"$plugin\".native // [] | join(\" \")" "$plugin_reg")
        fi

        # shellcheck disable=SC2086 # intentional word-splitting of space-separated lists
        expected=$(comm -23 <(printf '%s\n' $shared | sort) <(printf '%s\n' $native_set | sort) | tr '\n' ' ')
        expected="${expected% }"

        [[ "$harnesses" == "$expected" ]] || {
            echo "$plugin: harnesses {$harnesses} != expected {$expected} (shared {$shared} minus native {$native_set})" >&2
            return 1
        }
    done
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
    mkdir -p "$shim/Dev/dotfiles/chezmoi/lib" "$shim/Dev/dotfiles/skills"
    run env DOTFILES_DIR="$shim/Dev/dotfiles" bash -c '
        cp "$1/bin/dots" "$DOTFILES_DIR/dots"
        : > "$DOTFILES_DIR/skills/_registry.yaml"
        cat > "$DOTFILES_DIR/.sync" <<'"'"'SH'"'"'
#!/usr/bin/env bash
printf "DOTS_ACCEPT_AGENT_DRIFT=%s args=%s\n" "${DOTS_ACCEPT_AGENT_DRIFT:-}" "$*"
SH
        cat > "$DOTFILES_DIR/chezmoi/lib/install-external.sh" <<'"'"'SH'"'"'
#!/usr/bin/env bash
exit 0
SH
        chmod +x "$DOTFILES_DIR/.sync" "$DOTFILES_DIR/chezmoi/lib/install-external.sh"
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

@test "AC-7 every plugins/<name>/skills source in skills/_registry.yaml has a matching agents/plugins/registry.yaml entry" {
    local skills_reg="$DOTFILES_DIR/skills/_registry.yaml"
    local plugin_reg="$DOTFILES_DIR/agents/plugins/registry.yaml"
    local repo skills_path plugin

    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        skills_path=$(yq -r ".sources.\"$repo\".skills_path // \"\"" "$skills_reg")
        [[ "$skills_path" =~ ^plugins/([^/]+)/skills$ ]] || continue
        plugin="${BASH_REMATCH[1]}"
        run yq -e ".plugins.\"$plugin\"" "$plugin_reg"
        [[ $status -eq 0 ]] || {
            echo "skills source $repo declares skills_path plugins/$plugin/skills but agents/plugins/registry.yaml has no '$plugin' entry" >&2
            return 1
        }
    done < <(yq -r '.sources | keys | .[]' "$skills_reg")
}
