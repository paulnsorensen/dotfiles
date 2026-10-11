# shellcheck shell=sh
# MCP definitions come only from the managed global registry.
opencode_without_mcp() {
    if [ -z "$1" ]; then
        printf '{}\n'
        return 0
    fi
    printf '%s' "$1" | jq -es '
        if length == 1 and (.[0] | type) == "object" then
            .[0] | del(.mcp)
        else error("expected one JSON object") end
    ' 2>/dev/null || {
        printf 'OpenCode config is not a JSON object\n' >&2
        return 1
    }
}
