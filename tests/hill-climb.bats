#!/usr/bin/env bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."

@test "hill-climb ratchet unittest suite passes through the Bats gate" {
    run python3 -m unittest discover -s "$REPO_ROOT/tests/hill_climb" -t "$REPO_ROOT/tests" -p 'test_*.py'
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "hill-climb ratchet rejects a missing ratchet file with an input-error status" {
    run python3 "$REPO_ROOT/skills/hill-climb/scripts/ratchet.py" check --file "$BATS_TEST_TMPDIR/absent.json" --value a=1
    [ "$status" -eq 2 ]
    [[ "$output" == *"ratchet: "*"not found"* ]]
}
