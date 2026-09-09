#!/usr/bin/env bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."

@test "ci optimizer unittest suite passes through the Bats gate" {
    run python3 -m unittest discover -s "$REPO_ROOT/tests/ci_optimize" -p 'test_*.py'
    [ "$status" -eq 0 ]
}

@test "ci optimizer rejects malformed input with a failing status" {
    run python3 "$REPO_ROOT/skills/ci-optimize/scripts/ci_optimize.py" local --input /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"ci-optimize"* ]]
}
