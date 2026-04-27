#!/usr/bin/env bash
# Generate a worktree settings.local.json from dotfiles sources of truth.
#
# Sources:
#   claude/skills/*/             → Skill(name) permissions
#   claude/mcp/registry.yaml     → mcp__name__* permissions (user-scope MCPs)
#   claude/plugins/registry.yaml → mcp__plugin_<plugin>_<server>__* per server
#                                  declared in each plugin's .mcp.json
#   claude/settings.json         → mcp__claude_ai_* entries (Claude.ai integrations)
#
# Usage: bash claude/worktree-settings.sh [dotfiles-root]
# Output: JSON to stdout

set -euo pipefail

DOTFILES="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS_DIR="${DOTFILES}/claude/skills"
MCP_REGISTRY="${DOTFILES}/claude/mcp/registry.yaml"
PLUGIN_REGISTRY="${DOTFILES}/claude/plugins/registry.yaml"
SETTINGS_JSON="${DOTFILES}/claude/settings.json"
PLUGIN_CACHE="${HOME}/.claude/plugins/cache"

perms=()
perms+=("Edit" "Write" "LSP" "WebSearch" "WebFetch")

if [[ -d "${SKILLS_DIR}" ]]; then
    for skill_dir in "${SKILLS_DIR}"/*/; do
        name="$(basename "${skill_dir}")"
        perms+=("Skill(${name})")
    done
fi

if [[ -f "${MCP_REGISTRY}" ]]; then
    while IFS= read -r name; do
        [[ -n "${name}" ]] && perms+=("mcp__${name}__*")
    done < <(yq -r '.mcps | keys[]' "${MCP_REGISTRY}")
fi

# Resolve a plugin's .mcp.json path. Prefer registry `path:` (for local plugins),
# fall back to the marketplace cache. Emits empty string when no .mcp.json is
# present (skill-only plugins).
locate_plugin_mcp() {
    local plugin="$1" marketplace="$2" path_field="$3"
    if [[ -n "${path_field}" && "${path_field}" != "null" ]]; then
        local expanded="${path_field/#\~/${HOME}}"
        if [[ "${expanded}" != /* ]]; then
            expanded="${DOTFILES}/${expanded}"
        fi
        if [[ -f "${expanded}/.mcp.json" ]]; then
            echo "${expanded}/.mcp.json"
            return 0
        fi
    fi
    # Preserve caller's nullglob state so we don't leak the option globally.
    local nullglob_was_set=0
    if shopt -q nullglob; then
        nullglob_was_set=1
    fi
    shopt -s nullglob
    local candidates=("${PLUGIN_CACHE}/${marketplace}/${plugin}"/*/.mcp.json)
    if [[ ${nullglob_was_set} -eq 0 ]]; then
        shopt -u nullglob
    fi
    if [[ ${#candidates[@]} -gt 0 ]]; then
        echo "${candidates[0]}"
    fi
}

# Plugin .mcp.json may use either `{ "mcpServers": { name: ... } }` or a flat
# `{ name: ... }` layout. Return server names, one per line. Errors from jq
# (missing/invalid file) propagate so the script fails loudly under set -e.
read_mcp_servers() {
    jq -r 'if has("mcpServers") then .mcpServers | keys[] else keys[] end' "$1"
}

if [[ -f "${PLUGIN_REGISTRY}" ]]; then
    while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        plugin="${key%%@*}"
        marketplace="${key#*@}"
        [[ "${marketplace}" == "claude-code-lsps" ]] && continue

        path_field="$(yq -r ".plugins[\"${key}\"].path // \"\"" "${PLUGIN_REGISTRY}")"
        mcp_file="$(locate_plugin_mcp "${plugin}" "${marketplace}" "${path_field}")"
        [[ -z "${mcp_file}" ]] && continue

        # Capture servers via command substitution so jq failures trip set -e.
        servers="$(read_mcp_servers "${mcp_file}")"
        while IFS= read -r server; do
            [[ -n "${server}" ]] && perms+=("mcp__plugin_${plugin}_${server}__*")
        done <<< "${servers}"
    done < <(yq -r '.plugins | keys[]' "${PLUGIN_REGISTRY}")
fi

if [[ -f "${SETTINGS_JSON}" ]]; then
    while IFS= read -r entry; do
        [[ -n "${entry}" ]] && perms+=("${entry}")
    done < <(jq -r '.permissions.allow[]? | select(startswith("mcp__claude_ai_"))' "${SETTINGS_JSON}")
fi
jq -n \
    --argjson sandbox '{"enabled":true,"autoAllowBashIfSandboxed":true}' \
    --args \
    '{sandbox: $sandbox, permissions: {allow: $ARGS.positional | sort}}' \
    -- "${perms[@]}"
