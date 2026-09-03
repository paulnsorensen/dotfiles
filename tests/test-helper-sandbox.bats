#!/usr/bin/env bats
# Tests for the sandbox paths tests/test_helper.bash exports.
#
# WHY this matters: TEST_HOME is built from $TMPDIR, and macOS exports TMPDIR
# with a trailing slash. The resulting double slash survives in TEST_HOME but
# is collapsed by anything that normalizes a path (bash `cd` rewriting PWD,
# Python's os.path.abspath), so any test comparing normalized output against a
# raw "$TEST_HOME/..." literal failed on macOS and passed on CI. Two
# session-analytics tests sat red locally for exactly this reason.
#
# The tests that regressed only exercise this on macOS, so they cannot guard it
# on Linux CI. This file asserts the invariant directly, on every platform.

load test_helper

@test "sandbox: TEST_HOME contains no doubled separator" {
    [[ "$TEST_HOME" != *//* ]] || {
        echo "TEST_HOME is not normalized: $TEST_HOME" >&2
        return 1
    }
}

@test "sandbox: TEST_HOME survives cd unchanged" {
    # The property the session-analytics resolvers depend on: a path built from
    # $TEST_HOME and the same path after normalization are byte-identical.
    setup_test_env
    local seen
    seen="$(cd "$TEST_HOME" && pwd)"
    [ "$seen" = "$TEST_HOME" ]
    teardown_test_env
}

@test "sandbox: a trailing-slash TMPDIR still yields a normalized TEST_HOME" {
    # Reproduce the macOS export shape on any platform.
    local computed
    computed="$(TMPDIR="/var/folders/ab/cd/T/" bash -c '
        source "'"$REAL_DOTFILES_DIR"'/tests/test_helper.bash" >/dev/null 2>&1
        printf "%s" "$TEST_HOME"
    ')"
    [[ "$computed" != *//* ]] || {
        echo "trailing-slash TMPDIR leaked a doubled separator: $computed" >&2
        return 1
    }
    [[ "$computed" == /var/folders/ab/cd/T/dotfiles-test-* ]] || {
        echo "unexpected TEST_HOME shape: $computed" >&2
        return 1
    }
}
