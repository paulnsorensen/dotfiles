#!/usr/bin/env bats
# Tests for skills/session-analytics/scripts/db-path.sh — the shared
# session-analytics database path resolver sourced by every consumer script.

load test_helper

DB_PATH_SH="$REAL_DOTFILES_DIR/skills/session-analytics/scripts/db-path.sh"

setup() {
    setup_test_env
    unset XDG_CACHE_HOME SESSIONS_DB
}

teardown() { teardown_test_env; }

resolve() {
    bash -c "source '$DB_PATH_SH' && cd '$TEST_HOME' && sessions_db_path"
}

@test "db-path: default resolves under HOME/.cache" {
    run resolve
    assert_success
    [ "$output" = "$TEST_HOME/.cache/dotfiles/session-analytics/sessions.duckdb" ]
}

@test "db-path: SESSIONS_DB absolute is used as-is" {
    SESSIONS_DB="/opt/custom/sessions.duckdb" run resolve
    assert_success
    [ "$output" = "/opt/custom/sessions.duckdb" ]
}

@test "db-path: SESSIONS_DB relative resolves against PWD" {
    SESSIONS_DB="relative.duckdb" run resolve
    assert_success
    [ "$output" = "$TEST_HOME/relative.duckdb" ]
}

@test "db-path: XDG_CACHE_HOME absolute is honored" {
    XDG_CACHE_HOME="$TEST_HOME/custom-cache" run resolve
    assert_success
    [ "$output" = "$TEST_HOME/custom-cache/dotfiles/session-analytics/sessions.duckdb" ]
}

@test "db-path: XDG_CACHE_HOME relative is ignored" {
    XDG_CACHE_HOME="relative/cache" run resolve
    assert_success
    [ "$output" = "$TEST_HOME/.cache/dotfiles/session-analytics/sessions.duckdb" ]
}
