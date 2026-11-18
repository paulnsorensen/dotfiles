#!/usr/bin/env bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."

@test "architecture review unit tests pass through the Bats gate" {
    run python3 -B -m unittest discover -s "$REPO_ROOT/tests/architecture_review" -p 'test_*.py'
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "copied architecture review package runs outside the source tree" {
    package="$BATS_TEST_TMPDIR/architecture-review"
    repo="$BATS_TEST_TMPDIR/repo"
    cp -R "$REPO_ROOT/skills/architecture-review" "$package"
    [ -f "$package/SKILL.md" ]
    [ -f "$package/references/worker.md" ]
    [ -f "$package/scripts/evidence/snapshot.py" ]
    [ -f "$package/scripts/viewer.py" ]
    mkdir "$repo"
    git -C "$repo" init -q
    git -C "$repo" -c user.name=Test -c user.email=test@example.org commit -q --allow-empty -m initial
    run env XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache-home" python3 -B "$package/scripts/review.py" "$repo"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
    [[ "$output" == *'"worker_status": "repository"'* ]]
    [[ "$output" == *'"viewer": '* ]]
}
