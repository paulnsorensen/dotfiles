#!/bin/bash
# gen-profile-mcp.sh — Generate strict mcp.json for a profile.
#
# Reads:
#   claude/profiles/<name>/mcp-scope.yaml   (required — list of MCP names)
#   claude/profiles/<name>/mcp-add.json     (optional — profile-local MCPs)
#   claude/mcp/registry.yaml                (parent registry, source of truth)
#
# Validates each mcp-scope entry against the parent registry.
# Expands ${VAR} references in env values from .env + current shell.
# Emits a complete mcp.json to stdout (mcpServers object).
#
# Usage:
#   gen-profile-mcp.sh <profile-name> > mcp.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY="$DOTFILES_DIR/claude/mcp/registry.yaml"

profile="${1:-}"
[[ -n "$profile" ]] || { echo "usage: gen-profile-mcp.sh <profile-name>" >&2; exit 1; }

scope_file="$DOTFILES_DIR/claude/profiles/$profile/mcp-scope.yaml"
add_file="$DOTFILES_DIR/claude/profiles/$profile/mcp-add.json"

[[ -f "$scope_file" ]] || { echo "gen-profile-mcp: missing $scope_file" >&2; exit 1; }
[[ -f "$REGISTRY" ]]   || { echo "gen-profile-mcp: missing $REGISTRY" >&2; exit 1; }

# Load .env for secret expansion (same loader pattern as sync.sh)
if [[ -f "$DOTFILES_DIR/.env" ]]; then
    while IFS='=' read -r key val; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue
        export "$key=$val"
    done < "$DOTFILES_DIR/.env"
fi

REGISTRY_JSON=$(yq -o=json '.mcps' "$REGISTRY")
scope_names=$(yq -r '.mcps[]' "$scope_file")

# Validate every scope entry exists in the registry
for name in $scope_names; do
    if ! echo "$REGISTRY_JSON" | jq -e --arg n "$name" 'has($n)' >/dev/null; then
        echo "gen-profile-mcp: profile '$profile' references unknown MCP '$name' (not in $REGISTRY)" >&2
        exit 1
    fi
done

# Build mcpServers object from registry entries with env expansion
result='{"mcpServers":{}}'
for name in $scope_names; do
    entry=$(echo "$REGISTRY_JSON" | jq --arg n "$name" '.[$n]')
    cmd=$(echo "$entry" | jq -r '.command')
    args_json=$(echo "$entry" | jq -c '.args // []')
    env_in=$(echo "$entry" | jq -c '.env // {}')

    env_out='{}'
    while IFS=$'\t' read -r key val; do
        [[ -z "$key" ]] && continue
        if [[ "$val" =~ ^\$\{([^}]+)\}$ ]]; then
            var="${BASH_REMATCH[1]}"
            if [[ -z "${!var+x}" || -z "${!var}" ]]; then
                echo "gen-profile-mcp: env var \$$var required by $name.$key is unset" >&2
                exit 1
            fi
            val="${!var}"
        fi
        env_out=$(echo "$env_out" | jq --arg k "$key" --arg v "$val" '.[$k] = $v')
    done < <(echo "$env_in" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

    entry_final=$(jq -n \
        --arg cmd "$cmd" \
        --argjson args "$args_json" \
        --argjson env "$env_out" \
        '{command: $cmd, args: $args, env: $env}')
    result=$(echo "$result" | jq --arg n "$name" --argjson e "$entry_final" '.mcpServers[$n] = $e')
done

# Merge in any profile-local mcp-add.json (non-registry MCPs like shadcn for fe)
if [[ -f "$add_file" ]]; then
    add_json=$(cat "$add_file")
    # Validate add file shape
    if ! echo "$add_json" | jq -e '.mcpServers' >/dev/null 2>&1; then
        echo "gen-profile-mcp: $add_file missing .mcpServers" >&2
        exit 1
    fi
    result=$(jq -s '.[0].mcpServers * .[1].mcpServers | {mcpServers: .}' \
        <(echo "$result") <(echo "$add_json"))
fi

echo "$result" | jq .
