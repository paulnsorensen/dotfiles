#!/usr/bin/env bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."

@test "junit-to-weights unittest suite passes through the Bats gate" {
    run python3 -m unittest discover -s "$REPO_ROOT/tests/lib" -t "$REPO_ROOT/tests/lib" -p 'test_junit_to_weights.py'
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "junit-to-weights rejects malformed JUnit XML with a failing status" {
    run python3 "$REPO_ROOT/tests/lib/junit_to_weights.py" /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"junit-to-weights"* ]]
}
