#!/bin/bash
# hallouminate-install.sh — install the nightly binary and deliver the
# hallouminate plugin through each supported harness's native or decomposed path.

HALLOUMINATE_PACKAGE="@paulnsorensen/hallouminate-nightly"
HALLOUMINATE_REPO="https://github.com/paulnsorensen/hallouminate"

hallouminate_installed_version() {
    npm ls -g "$HALLOUMINATE_PACKAGE" --depth=0 2>/dev/null \
        | sed -n 's/.*hallouminate-nightly@//p' \
        | tr -d '[:space:]' || true
}

hallouminate_install_nightly() {
    if ! command -v npm >/dev/null 2>&1; then
        echo "  ERROR: npm not found — cannot install $HALLOUMINATE_PACKAGE. Install Node.js and rerun 'dots sync'." >&2
        return 1
    fi

    local latest current
    latest="$(npm view "$HALLOUMINATE_PACKAGE" version 2>/dev/null || true)"
    current="$(hallouminate_installed_version)"

    if [[ -n "$latest" && "$current" == "$latest" ]]; then
        echo "✓ hallouminate (nightly) $current already latest ($latest) — nothing to do"
    elif [[ -z "$latest" && -n "$current" ]]; then
        echo "⚠ Could not resolve latest $HALLOUMINATE_PACKAGE from npm (offline?) — keeping installed $current" >&2
    elif [[ -z "$latest" ]]; then
        echo "  ERROR: Could not resolve $HALLOUMINATE_PACKAGE from npm and no nightly is installed." >&2
        return 1
    else
        echo "Installing $HALLOUMINATE_PACKAGE@latest (was ${current:-none}, latest $latest)..."
        npm install -g "$HALLOUMINATE_PACKAGE@latest" --allow-scripts="$HALLOUMINATE_PACKAGE"
        current="$(hallouminate_installed_version)"
        if [[ -z "$current" ]]; then
            echo "  ERROR: npm reported success but $HALLOUMINATE_PACKAGE is not installed." >&2
            return 1
        fi
        echo "✓ hallouminate (nightly) $current installed"
    fi

    if npm ls -g hallouminate --depth=0 >/dev/null 2>&1; then
        echo "⚠ upstream public 'hallouminate' is also installed globally and competes for the 'hallouminate' bin — 'npm rm -g hallouminate' to keep the nightly fork canonical." >&2
    fi
    if [[ -f "$HOME/.cargo/bin/hallouminate" ]]; then
        echo "⚠ ~/.cargo/bin/hallouminate shadows the npm binary on PATH — remove it so 'hallouminate' resolves to the nightly fork." >&2
    fi
}

hallouminate_refresh_plugin_cache() {
    local cache="$1"
    local parent tmp

    if [[ -d "$cache/.git" ]]; then
        if git -C "$cache" fetch --depth=1 origin main >/dev/null 2>&1 \
            && git -C "$cache" reset --hard FETCH_HEAD >/dev/null 2>&1; then
            echo "✓ refreshed hallouminate plugin source ($cache)"
        elif [[ -f "$cache/.claude-plugin/marketplace.json" ]]; then
            echo "⚠ Could not refresh hallouminate plugin source (offline?) — using cached checkout." >&2
        else
            echo "  ERROR: hallouminate plugin cache is invalid and could not be refreshed: $cache" >&2
            return 1
        fi
        return 0
    fi

    if [[ -e "$cache" ]]; then
        echo "  ERROR: hallouminate plugin cache exists but is not a git checkout: $cache" >&2
        return 1
    fi

    parent="$(dirname "$cache")"
    mkdir -p "$parent"
    tmp="$cache.tmp.$$"
    rm -rf "$tmp"
    if ! git clone --depth=1 --branch=main "$HALLOUMINATE_REPO" "$tmp" >/dev/null 2>&1; then
        rm -rf "$tmp"
        echo "  ERROR: failed to clone hallouminate plugin source into $cache" >&2
        return 1
    fi
    mv "$tmp" "$cache"
    echo "✓ cloned hallouminate plugin source ($cache)"
}

hallouminate_payload_root() {
    local cache="$1"
    local marketplace="$cache/.claude-plugin/marketplace.json"
    local plugin_root source

    if ! command -v jq >/dev/null 2>&1; then
        echo "  ERROR: jq not found — cannot resolve or deploy the hallouminate plugin." >&2
        return 1
    fi
    if ! jq -e 'type == "object"' "$marketplace" >/dev/null 2>&1; then
        echo "  ERROR: invalid hallouminate marketplace manifest: $marketplace" >&2
        return 1
    fi

    plugin_root="$(jq -r '.metadata.pluginRoot // "."' "$marketplace")"
    source="$(jq -r '.plugins[] | select(.name == "hallouminate") | .source' "$marketplace")"
    if [[ -z "$source" || "$source" == "null" || "$plugin_root" == /* || "$source" == /* \
        || "/$plugin_root/" == *"/../"* || "/$source/" == *"/../"* ]]; then
        echo "  ERROR: unsafe or missing hallouminate payload path in $marketplace" >&2
        return 1
    fi

    printf '%s\n' "$cache/$plugin_root/$source"
}

_hallouminate_plugin_present() {
    local cli="$1"
    local installed="${HALLOUMINATE_CLAUDE_INSTALLED:-$HOME/.claude/plugins/installed_plugins.json}"

    if [[ "$cli" == "claude" ]]; then
        [[ -f "$installed" ]] || return 1
        jq -e '(.plugins["hallouminate@hallouminate"] // []) | any(.scope == "user")' "$installed" >/dev/null 2>&1
        return
    fi
    "$cli" plugin list 2>/dev/null | grep -q 'hallouminate'
}

_hallouminate_native_install() {
    local cli="$1" root="$2" install_verb="$3"

    if ! command -v "$cli" >/dev/null 2>&1; then
        echo "  NOTE: $cli CLI not found — native hallouminate plugin install skipped." >&2
        return 0
    fi

    "$cli" plugin marketplace add "$root" >/dev/null 2>&1 || true
    if "$cli" plugin "$install_verb" "hallouminate@hallouminate" >/dev/null 2>&1; then
        echo "✓ $cli native hallouminate plugin installed"
        return 0
    fi
    if _hallouminate_plugin_present "$cli"; then
        echo "✓ $cli native hallouminate plugin already installed"
        return 0
    fi

    echo "  ERROR: $cli could not install hallouminate@hallouminate." >&2
    return 1
}

_hallouminate_merge_mcp() {
    local harness="$1" file="$2" desired existing tmp

    mkdir -p "$(dirname "$file")"
    if [[ -f "$file" ]]; then
        if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
            echo "  ERROR: $harness config is not a valid JSON object; left untouched: $file" >&2
            return 1
        fi
    else
        printf '{}\n' > "$file"
    fi

    case "$harness" in
        opencode)
            desired='{"type":"local","enabled":true,"command":["hallouminate","serve"]}'
            existing="$(jq -c '.mcp.hallouminate // empty' "$file")"
            ;;
        cursor)
            desired='{"command":"hallouminate","args":["serve"]}'
            existing="$(jq -c '.mcpServers.hallouminate // empty' "$file")"
            ;;
        crush)
            desired='{"type":"stdio","command":"hallouminate","args":["serve"]}'
            existing="$(jq -c '.mcp.hallouminate // empty' "$file")"
            ;;
        *)
            echo "  ERROR: unsupported hallouminate MCP harness: $harness" >&2
            return 1
            ;;
    esac

    if [[ -n "$existing" && "$(jq -S . <<<"$existing")" != "$(jq -S . <<<"$desired")" ]]; then
        echo "  NOTE: $harness already has a user-owned hallouminate MCP entry; left untouched." >&2
        return 0
    fi
    if [[ -n "$existing" ]]; then
        return 0
    fi

    tmp="$file.tmp.$$"
    case "$harness" in
        opencode)
            jq --argjson desired "$desired" '.mcp = (.mcp // {}) | .mcp.hallouminate = $desired' "$file" > "$tmp"
            ;;
        cursor)
            jq --argjson desired "$desired" '.mcpServers = (.mcpServers // {}) | .mcpServers.hallouminate = $desired' "$file" > "$tmp"
            ;;
        crush)
            jq --argjson desired "$desired" '.mcp = (.mcp // {}) | .mcp.hallouminate = $desired' "$file" > "$tmp"
            ;;
    esac
    mv "$tmp" "$file"
    echo "✓ $harness hallouminate MCP configured ($file)"
}

_hallouminate_copy_skills() {
    local payload="$1"
    local shared_root="${HALLOUMINATE_SHARED_SKILLS:-$HOME/.agents/skills}"
    local opencode_root="${HALLOUMINATE_OPENCODE_SKILLS:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills}"
    local skill_dir name dest

    for skill_dir in "$payload"/skills/*; do
        [[ -f "$skill_dir/SKILL.md" ]] || continue
        name="$(basename "$skill_dir")"
        for dest in "$shared_root/$name" "$opencode_root/$name"; do
            if [[ -e "$dest" ]]; then
                continue
            fi
            mkdir -p "$(dirname "$dest")"
            cp -R "$skill_dir" "$dest"
        done
    done
}

hallouminate_sync_plugins() {
    local cache="$1"
    local payload
    local opencode_cfg="${HALLOUMINATE_OPENCODE_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json}"
    local cursor_cfg="${HALLOUMINATE_CURSOR_CONFIG:-$HOME/.cursor/mcp.json}"
    local crush_cfg="${HALLOUMINATE_CRUSH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/crush/crush.json}"

    hallouminate_refresh_plugin_cache "$cache"
    payload="$(hallouminate_payload_root "$cache")"
    if [[ ! -d "$payload" ]]; then
        echo "  ERROR: hallouminate plugin payload not found: $payload" >&2
        return 1
    fi

    _hallouminate_native_install claude "$cache" install
    _hallouminate_native_install codex "$cache" add
    _hallouminate_native_install copilot "$cache" install

    _hallouminate_merge_mcp opencode "$opencode_cfg"
    _hallouminate_merge_mcp cursor "$cursor_cfg"
    _hallouminate_merge_mcp crush "$crush_cfg"
    _hallouminate_copy_skills "$payload"
}
