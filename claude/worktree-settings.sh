#!/usr/bin/env bash
# Generate a worktree settings.local.json from dotfiles sources of truth.
#
# Sources:
#   claude/skills/*/           → Skill(name) permissions
#   claude/mcp/registry.yaml   → mcp__name__* permissions
#   claude/plugins/registry.yaml → mcp__plugin_name_name__* (non-LSP only)
#   claude/settings.json       → mcp__claude_ai_* entries (Claude.ai integrations)
#
# Usage: bash claude/worktree-settings.sh [dotfiles-root]
# Output: JSON to stdout

set -euo pipefail

DOTFILES="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SKILLS_DIR="${DOTFILES}/claude/skills"
MCP_REGISTRY="${DOTFILES}/claude/mcp/registry.yaml"
PLUGIN_REGISTRY="${DOTFILES}/claude/plugins/registry.yaml"
SETTINGS_JSON="${DOTFILES}/claude/settings.json"

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

if [[ -f "${PLUGIN_REGISTRY}" ]]; then
    while IFS= read -r key; do
        [[ -z "${key}" ]] && continue
        plugin="${key%%@*}"
        marketplace="${key#*@}"
        # LSP plugins don't provide MCP tools
        [[ "${marketplace}" == "claude-code-lsps" ]] && continue
        # Claude Code normalizes hyphens to underscores in tool names
        normalized="${plugin//-/_}"
        perms+=("mcp__plugin_${normalized}_${normalized}__*")
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
