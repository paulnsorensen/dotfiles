#!/usr/bin/env bash
# Test helper functions for bats tests

# Get the actual dotfiles directory (where the tests are)
export REAL_DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$REAL_DOTFILES_DIR/bin:$PATH"

# Test environment setup
export TEST_HOME="/tmp/dotfiles-test-$$"

# Override DOTFILES_DIR for tests to point to the real location
export DOTFILES_DIR="$REAL_DOTFILES_DIR"
export DOTFILES_STATE_DIR="$TEST_HOME/.local/state/dotfiles"

# Colors for test output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# Setup test environment
setup_test_env() {
    # Create test home directory
    mkdir -p "$TEST_HOME"
    mkdir -p "$DOTFILES_STATE_DIR"
    
    # Backup original HOME
    export ORIGINAL_HOME="$HOME"
    export HOME="$TEST_HOME"
}

# Teardown test environment
teardown_test_env() {
    # Restore original HOME
    export HOME="$ORIGINAL_HOME"
    
    # Clean up test directory
    if [[ -d "$TEST_HOME" ]]; then
        rm -rf "$TEST_HOME"
    fi
}

# Create a mock git repository
create_mock_repo() {
    local dir="${1:-$TEST_HOME/mock-dotfiles}"
    mkdir -p "$dir"
    cd "$dir"
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "test" > test.txt
    git add test.txt
    git commit -m "Initial commit" --quiet
    cd - > /dev/null
}

# Assert file exists
assert_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "File does not exist: $file" >&2
        return 1
    fi
}

# Assert directory exists
assert_dir_exists() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "Directory does not exist: $dir" >&2
        return 1
    fi
}

# Assert symlink exists and points to target
assert_symlink() {
    local link="$1"
    local target="$2"
    
    if [[ ! -L "$link" ]]; then
        echo "Not a symlink: $link" >&2
        return 1
    fi
    
    local actual_target=$(readlink "$link")
    if [[ "$actual_target" != "$target" ]]; then
        echo "Symlink $link points to $actual_target, not $target" >&2
        return 1
    fi
}

# Assert command succeeds (works with bats 'run' which sets $status)
assert_success() {
    if [[ ${status:-$?} -ne 0 ]]; then
        echo "Command failed with exit code ${status:-$?}" >&2
        return 1
    fi
}

# Assert command fails (works with bats 'run' which sets $status)
assert_failure() {
    if [[ ${status:-$?} -eq 0 ]]; then
        echo "Command succeeded but should have failed" >&2
        return 1
    fi
}

# Strip ANSI color codes from text
strip_colors() {
    echo "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Assert output contains string
assert_output_contains() {
    local expected="$1"
    local actual="${2:-$output}"
    
    # Strip colors from actual output if not already done
    if [[ "$actual" == *$'\x1b'* ]]; then
        actual=$(strip_colors "$actual")
    fi
    
    if [[ "$actual" != *"$expected"* ]]; then
        echo "Output does not contain: $expected" >&2
        echo "Actual output: $actual" >&2
        return 1
    fi
}

# Assert output does not contain string
assert_output_not_contains() {
    local unexpected="$1"
    local actual="${2:-$output}"
    
    if [[ "$actual" == *"$unexpected"* ]]; then
        echo "Output contains unexpected: $unexpected" >&2
        echo "Actual output: $actual" >&2
        return 1
    fi
}