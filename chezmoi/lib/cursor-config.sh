#!/bin/sh
# Reconcile the Cursor MCP key owned by chezmoi and preserve other live keys.

cursor_config_merge() {
    live=$1
    desired=$2
    if [ -z "$live" ]; then
        live='{}'
    fi
    if ! printf '%s' "$live" | jq -e 'type == "object" and (.mcpServers == null or (.mcpServers | type == "object"))' >/dev/null 2>&1; then
        echo 'modify_mcp.json: live Cursor config is not a JSON object' >&2
        return 1
    fi
    jq -n --argjson live "$live" --argjson desired "$desired" '
        $live
        | if $desired.milknado then
            .mcpServers = ((.mcpServers // {}) + {milknado: $desired.milknado})
          else
            del(.mcpServers.milknado)
            | if .mcpServers == {} then del(.mcpServers) else . end
          end
    '
}
