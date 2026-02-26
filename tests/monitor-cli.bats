#!/usr/bin/env bats
# CLI argument and session discovery tests for claude-monitor
load monitor_helper

@test "help flag exits 0 and shows usage" {
    run "$MONITOR" --help
    [[ $status -eq 0 ]]
    assert_contains "Usage: claude-monitor"
}

@test "-h flag shows usage" {
    run "$MONITOR" -h
    [[ $status -eq 0 ]]
    assert_contains "Usage: claude-monitor"
}

@test "unknown flag exits non-zero" {
    run "$MONITOR" --bogus-flag-xyz
    [[ $status -ne 0 ]]
    assert_contains "Unknown option"
}

@test "no session found exits 1 with --once" {
    HOME="$FAKE_HOME" run "$MONITOR" --cwd /no/such/path --once
    [[ $status -ne 0 ]]
    assert_contains "No active session found"
}

@test "project dir exists but no JSONL files — exits 1" {
    make_project "/test/no-jsonl"
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/test/no-jsonl" --once
    [[ $status -ne 0 ]]
    assert_contains "No active session found"
}

@test "waiting message shows encoded path" {
    HOME="$FAKE_HOME" run "$MONITOR" --cwd "/my/test/path" --once
    [[ $status -ne 0 ]]
    [[ -n "$output" ]]
}
