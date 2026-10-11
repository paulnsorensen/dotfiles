#!/usr/bin/env bats
# Verify the package owns the DuckDB memory limit.
load test_helper
load lib/session-analytics-package

QUERY_SH="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/query.sh"

setup() {
    setup_test_env
    package_fixture_env
}

teardown() { teardown_test_env; }

@test "duckdb-memory: SQL uses the default 8GB limit" {
    package_fixture_ingest >/dev/null
    run "$QUERY_SH" sql "SELECT current_setting('memory_limit') AS m"
    assert_success
    assert_output_contains "7.4 GiB"
}

@test "duckdb-memory: SQL honors SESSIONS_DUCKDB_MEMORY_LIMIT" {
    package_fixture_ingest >/dev/null
    SESSIONS_DUCKDB_MEMORY_LIMIT=1GB run "$QUERY_SH" sql "SELECT current_setting('memory_limit') AS m"
    assert_success
    assert_output_contains "953.6 MiB"
}

@test "duckdb-memory: package ingest passes the cap to DuckDB" {
    local bindir="$TEST_HOME/bin"
    local log="$TEST_HOME/duckdb-argv.log"
    local duckdb_real
    duckdb_real="$(command -v duckdb)"
    mkdir -p "$bindir"
    cat > "$bindir/duckdb" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$log"
exec "$duckdb_real" "\$@"
SHIM
    chmod +x "$bindir/duckdb"
    PATH="$bindir:$PATH" run package_fixture_ingest
    assert_success
    [[ "$(< "$log")" == *"SET memory_limit='8GB'"* ]]
}
