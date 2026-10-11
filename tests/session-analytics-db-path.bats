#!/usr/bin/env bats
# Test the published package path contract.
load test_helper
load lib/session-analytics-package

setup() {
    setup_test_env
    package_fixture_env
}

teardown() { teardown_test_env; }

@test "db-path: default resolves under HOME/.cache" {
    unset XDG_CACHE_HOME
    run package_fixture_db
    assert_success
    [ "$output" = "$TEST_HOME/.cache/dotfiles/session-analytics/sessions.duckdb" ]
}

@test "db-path: absolute SESSIONS_DB is used as-is" {
    SESSIONS_DB="/opt/custom/sessions.duckdb" run package_fixture_db
    assert_success
    [ "$output" = "/opt/custom/sessions.duckdb" ]
}

@test "db-path: relative SESSIONS_DB resolves against PWD" {
    cd "$TEST_HOME" || return
    SESSIONS_DB="relative.duckdb" run package_fixture_db
    assert_success
    [ "$output" = "$TEST_HOME/relative.duckdb" ]
}

@test "db-path: absolute XDG_CACHE_HOME is honored" {
    XDG_CACHE_HOME="$TEST_HOME/custom-cache" run package_fixture_db
    assert_success
    [ "$output" = "$TEST_HOME/custom-cache/dotfiles/session-analytics/sessions.duckdb" ]
}

@test "db-path: relative XDG_CACHE_HOME is ignored" {
    XDG_CACHE_HOME="relative/cache" run package_fixture_db
    assert_success
    [ "$output" = "$TEST_HOME/.cache/dotfiles/session-analytics/sessions.duckdb" ]
}
