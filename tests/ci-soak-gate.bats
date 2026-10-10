#!/usr/bin/env bats
# Tests for bin/ci-soak-gate — CI glue for the soak hold and the aggregate gate.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
GATE="$DOTFILES_DIR/bin/ci-soak-gate"
HOLD="skills/harness-climb/scripts/soak_check.py"
PIN="chezmoi/dot_config/mise/config.toml"

setup() {
    TMPROOT="$(mktemp -d)"
    REPO="$TMPROOT/repo"
    MOCK_BIN="$TMPROOT/bin"
    mkdir -p "$REPO" "$MOCK_BIN"
    git -C "$REPO" init -b main -q
    git -C "$REPO" config user.email t@t.test
    git -C "$REPO" config user.name tester
    mkdir -p "$REPO/${HOLD%/*}" "$REPO/${PIN%/*}"
    echo a > "$REPO/$HOLD"
    echo a > "$REPO/$PIN"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m base
    BASE="$(git -C "$REPO" rev-parse HEAD)"
}

teardown() {
    rm -rf "$TMPROOT"
}

mock_gh() {
    printf '#!/bin/bash\n%s\n' "$1" > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}

assert_gate() {
    EVENT="$1" SHARDS="$2" EXTRAS="$3" SOAK="$4" run "$GATE" assert
}

@test "labels prints the joined label list from gh" {
    mock_gh 'echo "area,harness-climb/soak-override"'
    PATH="$MOCK_BIN:$PATH" PR_NUMBER=7 REPO=o/r run "$GATE" labels
    [ "$status" -eq 0 ]
    [ "$output" = "area,harness-climb/soak-override" ]
}

@test "labels fails closed when gh fails" {
    mock_gh 'exit 1'
    PATH="$MOCK_BIN:$PATH" PR_NUMBER=7 REPO=o/r run "$GATE" labels
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot read PR labels"* ]]
}

@test "guard fails when one PR changes the hold and the pin file" {
    echo b >> "$REPO/$HOLD"
    echo b >> "$REPO/$PIN"
    git -C "$REPO" commit -q -am both
    cd "$REPO"
    run "$GATE" guard "$BASE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"split them"* ]]
}

@test "guard fails when one PR changes another hold module and the pin file" {
    echo b > "$REPO/${HOLD%/*}/hc_stats.py"
    echo b >> "$REPO/$PIN"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m module-and-pin
    cd "$REPO"
    run "$GATE" guard "$BASE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"split them"* ]]
}

@test "guard fails when one PR changes the gate script and the pin file" {
    mkdir -p "$REPO/bin"
    echo b > "$REPO/bin/ci-soak-gate"
    echo b >> "$REPO/$PIN"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m gate-and-pin
    cd "$REPO"
    run "$GATE" guard "$BASE"
    [ "$status" -eq 1 ]
}

@test "guard passes when the PR changes only the hold" {
    echo b >> "$REPO/$HOLD"
    git -C "$REPO" commit -q -am hold
    cd "$REPO"
    run "$GATE" guard "$BASE"
    [ "$status" -eq 0 ]
}

@test "guard passes when the PR changes only the pin file" {
    echo b >> "$REPO/$PIN"
    git -C "$REPO" commit -q -am pin
    cd "$REPO"
    run "$GATE" guard "$BASE"
    [ "$status" -eq 0 ]
}

@test "assert passes on pull_request when every job succeeds" {
    assert_gate pull_request success success success
    [ "$status" -eq 0 ]
}

@test "assert fails on pull_request when soak-check is skipped" {
    assert_gate pull_request success success skipped
    [ "$status" -eq 1 ]
}

@test "assert accepts a skipped soak-check on push" {
    assert_gate push success success skipped
    [ "$status" -eq 0 ]
}

@test "assert rejects a skipped or failed shard on push" {
    assert_gate push skipped success success
    [ "$status" -eq 1 ]
    assert_gate push success failure success
    [ "$status" -eq 1 ]
}

@test "assert rejects a failed soak-check on push" {
    assert_gate push success success failure
    [ "$status" -eq 1 ]
}
