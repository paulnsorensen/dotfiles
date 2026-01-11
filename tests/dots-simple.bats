#!/usr/bin/env bats
# Simple tests for the dots command that don't require HOME manipulation

# Get the dotfiles directory
export DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"

# Simple assert functions
assert_success() {
    [[ $status -eq 0 ]] || {
        echo "Command failed with status $status"
        return 1
    }
}

assert_failure() {
    [[ $status -ne 0 ]] || {
        echo "Command succeeded but should have failed"
        return 1
    }
}

assert_contains() {
    local haystack="${2:-$output}"
    # Strip colors
    haystack=$(echo "$haystack" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$haystack" == *"$1"* ]] || {
        echo "Output does not contain: $1"
        echo "Actual: $haystack"
        return 1
    }
}

@test "dots command exists" {
    [[ -x "$DOTFILES_DIR/bin/dots" ]]
}

@test "dots help works" {
    run dots help
    assert_success
    assert_contains "Usage: dots"
    assert_contains "update"
    assert_contains "sync"
}

@test "dots status works" {
    run dots status
    assert_success
    assert_contains "Dotfiles Status"
}

@test "dots handles invalid command" {
    run dots invalid_command_xyz
    assert_failure
    assert_contains "Unknown command"
}

@test "dots shorthand h works" {
    run dots h
    assert_success
    assert_contains "Usage: dots"
}

@test "dots doctor runs with profiling" {
    run timeout 10 dots doctor
    assert_success
    assert_contains "Health Check"
    assert_contains "Profiling shell startup"
}

@test "dots test help works" {
    run dots test -h
    assert_success
    assert_contains "Usage"
}