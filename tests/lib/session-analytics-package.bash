#!/usr/bin/env bash
# Isolated session logs for package-backed Bats tests.
# -q keeps uv install progress out of asserted output; the sandbox starts with a cold uv cache.
PACKAGE_CLI=(uvx -q agent-session-analytics@latest)

package_real_binary() {
    local candidate
    while IFS= read -r candidate; do
        if [[ "$candidate" != */shims/* ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(type -a -P "$1")
    command -v mise >/dev/null && mise which "$1"
}

package_fixture_env() {
    local uvx_bin duckdb_bin
    uvx_bin="$(package_real_binary uvx)" || return
    duckdb_bin="$(package_real_binary duckdb)" || return
    export PATH="${uvx_bin%/*}:${duckdb_bin%/*}:$PATH"
    export HOME="$TEST_HOME"
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    export CLAUDE_CONFIG_DIR="$TEST_HOME/.claude"
    export CODEX_HOME="$TEST_HOME/.codex"
    export CURSOR_HOME="$TEST_HOME/.cursor"
    unset SESSIONS_DB SESSIONS_DUCKDB_MEMORY_LIMIT
    mkdir -p "$CLAUDE_CONFIG_DIR/projects/proj"
}

package_fixture_ingest() {
    printf '%s\n' \
        '{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"c-1","cwd":"/work/fixture","gitBranch":"main","message":{"content":[{"type":"tool_use","id":"tu-1","name":"Read","input":{"file_path":"README.md"}},{"type":"tool_use","id":"tu-2","name":"Bash","input":{"command":"echo hi"}}]}}' \
        '{"type":"user","timestamp":"2026-05-30T10:00:01Z","sessionId":"c-1","message":{"content":[{"type":"tool_result","tool_use_id":"tu-1","content":"ok","is_error":"false"},{"type":"tool_result","tool_use_id":"tu-2","content":"blocked","is_error":"true"}]}}' \
        > "$CLAUDE_CONFIG_DIR/projects/proj/session.jsonl"
    "${PACKAGE_CLI[@]}" ingest --force
}

package_fixture_db() {
    "${PACKAGE_CLI[@]}" db-path | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])'
}
