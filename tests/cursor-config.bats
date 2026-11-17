#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export SCRIPT="$CZ_SRC/dot_cursor/modify_mcp.json"
}

@test "Cursor Milknado defaults off without changing other keys" {
    for value in unset false 1; do
        if [ "$value" = unset ]; then
            run env -u MILKNADO_ENABLED CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"mcpServers":{"milknado":{"command":"uvx"},"sentinel":{"command":"keep"}},"extraKey":7}
JSON
        else
            run env MILKNADO_ENABLED="$value" CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"mcpServers":{"milknado":{"command":"uvx"},"sentinel":{"command":"keep"}},"extraKey":7}
JSON
        fi
        [ "$status" -eq 0 ]
        [ "$(jq -cS . <<<"$output")" = '{"extraKey":7,"mcpServers":{"sentinel":{"command":"keep"}}}' ]
    done
}

@test "Cursor Milknado true restores the source launcher without gate metadata" {
    run env MILKNADO_ENABLED=true CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"mcpServers":{"sentinel":{"command":"keep"}},"extraKey":7}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -cS . <<<"$output")" = '{"extraKey":7,"mcpServers":{"milknado":{"args":["--from","git+https://github.com/paulnsorensen/milknado@main","milknado-mcp"],"command":"uvx"},"sentinel":{"command":"keep"}}}' ]
    run env -u MILKNADO_ENABLED CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<<"$output"
    [ "$status" -eq 0 ]
    [ "$(jq -cS . <<<"$output")" = '{"extraKey":7,"mcpServers":{"sentinel":{"command":"keep"}}}' ]
}

@test "Cursor modifier rejects malformed live JSON" {
    run --separate-stderr env MILKNADO_ENABLED=true CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<<'{"mcpServers":'
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
