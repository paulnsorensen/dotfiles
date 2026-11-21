#!/usr/bin/env bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."

@test "review-leverage unittest suite passes through the Bats gate" {
    run python3 -m unittest discover -s "$REPO_ROOT/tests/review_leverage" -t "$REPO_ROOT/tests" -p 'test_*.py'
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "review-leverage rejects an unknown subcommand with a failing status" {
    run python3 "$REPO_ROOT/skills/review-leverage/scripts/review_leverage.py" approve
    [ "$status" -eq 2 ]
    [[ "$output" == *"review-leverage"* ]]
}
