#!/usr/bin/env bats
# Tests for the duckdb memory_limit cap (SESSIONS_DUCKDB_MEMORY_LIMIT).
#
# -init /dev/null on every duckdb invocation suppresses the ~/.duckdbrc
# banner but also skips its SET memory_limit='8GB' -- silently uncapping
# duckdb inside the 40GB user slice. query.sh and ingest.py must each pass
# an explicit -cmd "SET memory_limit=..." so the cap survives regardless
# of the rc file.

load test_helper

DB_PATH_SH="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/db-path.sh"
QUERY_SH="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/query.sh"
INGEST="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/ingest.py"

setup() {
    setup_test_env
    command -v duckdb >/dev/null || skip "duckdb not installed"
    DUCKDB_REAL="$(command -v duckdb)"
    unset SESSIONS_DUCKDB_MEMORY_LIMIT SESSIONS_DB
}

teardown() { teardown_test_env; }

# --- sessions_duckdb_memory_limit ------------------------------------------

@test "duckdb-memory: sessions_duckdb_memory_limit defaults to 8GB" {
    run bash -c "source '$DB_PATH_SH' && sessions_duckdb_memory_limit"
    assert_success
    [ "$output" = "8GB" ]
}

@test "duckdb-memory: sessions_duckdb_memory_limit honors SESSIONS_DUCKDB_MEMORY_LIMIT" {
    SESSIONS_DUCKDB_MEMORY_LIMIT=2GB run bash -c "source '$DB_PATH_SH' && sessions_duckdb_memory_limit"
    assert_success
    [ "$output" = "2GB" ]
}

# --- query.sh applies the cap despite -init /dev/null ----------------------

make_fixture_db() {
    local db="$TEST_HOME/fixture.duckdb"
    duckdb -init /dev/null "$db" -c "CREATE TABLE tool_uses (id INTEGER);" >/dev/null
    printf '%s\n' "$db"
}

@test "duckdb-memory: query.sh sql reports the default 8GB cap, not the rc's uncapped state" {
    local db
    db="$(make_fixture_db)"
    SESSIONS_DB="$db" run "$QUERY_SH" sql "SELECT current_setting('memory_limit') AS m"
    assert_success
    assert_output_contains "7.4 GiB"
}

@test "duckdb-memory: query.sh sql honors SESSIONS_DUCKDB_MEMORY_LIMIT=1GB" {
    local db
    db="$(make_fixture_db)"
    SESSIONS_DB="$db" SESSIONS_DUCKDB_MEMORY_LIMIT=1GB run "$QUERY_SH" sql "SELECT current_setting('memory_limit') AS m"
    assert_success
    assert_output_contains "953.6 MiB"
}

# --- ingest.py's duckdb calls carry the cap --------------------------------

@test "duckdb-memory: ingest.py passes the memory_limit cap to every duckdb invocation" {
    local bindir="$TEST_HOME/bin"
    local log="$TEST_HOME/duckdb-argv.log"
    mkdir -p "$bindir" "$TEST_HOME/.claude/projects/proj"
    cat > "$bindir/duckdb" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$log"
exec "$DUCKDB_REAL" "\$@"
SHIM
    chmod +x "$bindir/duckdb"
    cat > "$TEST_HOME/.claude/projects/proj/sess.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-05-30T10:00:00Z","sessionId":"c-1","cwd":"/work","message":{"content":[{"type":"tool_use","id":"tu-1","name":"Read","input":{}}]}}
JSONL
    XDG_CACHE_HOME="$TEST_HOME/.cache" PATH="$bindir:$PATH" run python3 "$INGEST" --force
    assert_success
    grep -q "SET memory_limit='8GB'" "$log"
}
