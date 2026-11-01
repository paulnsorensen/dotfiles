#!/usr/bin/env bats
load lib/session-analytics-package

@test "cache warmer rejects a cold offline cache and releases its lock" {
    export BATS_RUN_TMPDIR="$BATS_TEST_TMPDIR/cold"
    command mkdir -p "$BATS_RUN_TMPDIR"
    export UV_OFFLINE=1
    run package_warm_cache
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_RUN_TMPDIR/session-analytics-uv/warm" ]
    [ ! -e "$BATS_RUN_TMPDIR/session-analytics-uv.lock" ]
}

@test "cache consumers use the exact supported package version" {
    [ "${PACKAGE_CLI[*]}" = "uvx -q agent-session-analytics==0.2.1" ]
}

@test "cache warmer rechecks a marker published before lock acquisition" {
    export BATS_RUN_TMPDIR="$BATS_TEST_TMPDIR/race"
    command mkdir -p "$BATS_RUN_TMPDIR"
    # Simulate another caller publishing its marker before this caller acquires the lock.
    mkdir() {
        command mkdir "$@" || return
        if [[ "$1" == "$BATS_RUN_TMPDIR/session-analytics-uv.lock" ]]; then
            command mkdir -p "$BATS_RUN_TMPDIR/session-analytics-uv"
            touch "$BATS_RUN_TMPDIR/session-analytics-uv/warm"
        fi
    }
    record_warm() { touch "$BATS_TEST_TMPDIR/called"; }
    PACKAGE_CLI=(record_warm)
    run package_warm_cache
    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/called" ]
    [ ! -e "$BATS_RUN_TMPDIR/session-analytics-uv.lock" ]
}
