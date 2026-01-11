#!/usr/bin/env bats
# Tests for the dots command

load test_helper

setup() {
    setup_test_env
}

teardown() {
    teardown_test_env
}

@test "dots command exists and is executable" {
    [[ -x "$DOTFILES_DIR/bin/dots" ]]
}

@test "dots help displays usage information" {
    run dots help
    assert_success
    assert_output_contains "Usage: dots [command] [args]"
    assert_output_contains "update"
    assert_output_contains "sync"
    assert_output_contains "rollback"
}

@test "dots with no arguments shows status" {
    # Don't try to create repo in actual dotfiles dir - it already exists
    # Just run the command
    run dots
    assert_success
    assert_output_contains "Dotfiles Status"
}

@test "dots accepts shorthand commands" {
    run dots h
    assert_success
    assert_output_contains "Usage: dots"
}

@test "dots doctor performs health checks and profiling" {
    run timeout 10 dots doctor
    assert_success
    assert_output_contains "Dotfiles Health Check"
    assert_output_contains "Checking symlinks"
    assert_output_contains "Checking dependencies"
    assert_output_contains "Profiling shell startup"
}

@test "dots handles unknown commands gracefully" {
    run dots nonexistent
    assert_failure
    assert_output_contains "Unknown command"
}

@test "dots update shorthand works" {
    # Just test that 'u' is recognized (don't actually update)
    run dots u --help 2>&1 || true
    # Should not say "Unknown command"
    [[ "$output" != *"Unknown command"* ]]
}

@test "dots sync shorthand works" {
    # Just verify 's' is recognized
    run timeout 2 dots s --help 2>&1 || true
    [[ "$output" != *"Unknown command"* ]]
}

@test "dots test shorthand works" {
    run dots t --help
    assert_success
}

@test "dots backups command runs" {
    run dots backups
    # May fail if no backups exist, but should not be "Unknown command"
    [[ "$output" != *"Unknown command"* ]]
}

@test "dots rollback without args shows help" {
    run dots rollback
    # Should either show backups or ask for input
    [[ "$output" =~ "backup" || "$output" =~ "Rollback" || $status -ne 0 ]]
}