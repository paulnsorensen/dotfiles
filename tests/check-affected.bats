#!/usr/bin/env bats
# The affected-only `just check` gate: selector unit tests and the dispatcher.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
    FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/check-affected.XXXXXX")"
    mkdir -p "$FIXTURE/tests/lib" "$FIXTURE/docs" "$FIXTURE/stub"
    cp "$REPO_ROOT/tests/check-affected.sh" "$FIXTURE/tests/"
    cp "$REPO_ROOT/tests/lib/affected.py" "$FIXTURE/tests/lib/"
    printf '# Guide\n' > "$FIXTURE/docs/guide.md"
    # A stub `just` records each leg it runs; STUB_FAIL names a leg that fails.
    cat > "$FIXTURE/stub/just" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
[[ "$1" != "${STUB_FAIL:-}" ]]
EOF
    chmod +x "$FIXTURE/stub/just"
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" add .
    git -C "$FIXTURE" -c user.name=t -c user.email=t@t commit -qm fixture
    export STUB_LOG="$FIXTURE/just.log" PATH="$FIXTURE/stub:$PATH"
    # The stub log is untracked, so keep it out of the change set.
    printf 'just.log\n' > "$FIXTURE/.git/info/exclude"
}

teardown() {
    rm -rf "$FIXTURE"
}

@test "affected selector unittest suite passes through the Bats gate" {
    run python3 -m unittest discover -s "$REPO_ROOT/tests/lib" -t "$REPO_ROOT/tests/lib" -p 'test_affected.py'
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "check --all --plan lists every leg as a whole-leg run" {
    run "$REPO_ROOT/tests/check-affected.sh" --all --plan
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' test test-python lint-shell lint-markdown smoke lint-js lint-python)" ]
}

@test "check rejects an unknown option with usage" {
    run "$REPO_ROOT/tests/check-affected.sh" --bogus
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown option '--bogus'"* ]]
    [[ "$output" == *"Usage: just check"* ]]
}

@test "check with no changes runs nothing" {
    run "$FIXTURE/tests/check-affected.sh" --base HEAD
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to run"* ]]
    [ ! -e "$STUB_LOG" ]
}

@test "check runs markdown lint only on a changed Markdown file" {
    printf '# Guide v2\n' > "$FIXTURE/docs/guide.md"
    printf '# New\n' > "$FIXTURE/docs/new.md"
    run "$FIXTURE/tests/check-affected.sh" --base HEAD
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_LOG")" = "lint-markdown docs/guide.md docs/new.md" ]
    [[ "$output" == *"lint-markdown"*"ok"* ]]
}

@test "check fails when a selected leg fails and names the leg" {
    printf '# Guide v2\n' > "$FIXTURE/docs/guide.md"
    STUB_FAIL=lint-markdown run "$FIXTURE/tests/check-affected.sh" --base HEAD
    [ "$status" -ne 0 ]
    [[ "$output" == *"lint-markdown"*"FAIL"* ]]
}

@test "a change to the gate itself runs every leg in parallel" {
    printf '\n' >> "$FIXTURE/tests/check-affected.sh"
    run "$FIXTURE/tests/check-affected.sh" --base HEAD
    [ "$status" -eq 0 ]
    [ "$(sort "$STUB_LOG")" = "$(printf '%s\n' lint-js lint-markdown lint-python lint-shell smoke test test-python)" ]
}
