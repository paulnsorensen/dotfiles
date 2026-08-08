#!/usr/bin/env bats
# Behavioral tests for bin/dots profile delegation. The cheese stub records
# exact argv and emits distinct streams/status so the wrapper contract is
# observable without invoking the installed engine.

load test_helper

setup() {
    TEST_ROOT="$(mktemp -d)"
    MOCK_BIN="$TEST_ROOT/bin"
    mkdir -p "$MOCK_BIN"

    export PATH="$MOCK_BIN:$PATH"
    export DOTFILES_DIR="$TEST_ROOT/dotfiles root"
    export DOTFILES_STATE_DIR="$TEST_ROOT/state"
    export PROFILE_STDOUT="$TEST_ROOT/stdout"
    export PROFILE_STDERR="$TEST_ROOT/stderr"
    export CHEESE_ARGS="$TEST_ROOT/cheese-args"
    export CHEESE_STATUS=23
    mkdir -p "$DOTFILES_DIR" "$DOTFILES_STATE_DIR"

    cat > "$MOCK_BIN/cheese" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CHEESE_ARGS"
printf 'engine stdout\n'
printf 'engine stderr\n' >&2
exit "${CHEESE_STATUS:-0}"
EOF
    chmod +x "$MOCK_BIN/cheese"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

_run_profile() {
    run bash -c '
        "$REAL_DOTFILES_DIR/bin/dots" "$@" >"$PROFILE_STDOUT" 2>"$PROFILE_STDERR"
    ' _ "$@"
}

_run_profile_from() {
    local cwd="$1"
    shift
    run bash -c '
        cd -- "$1" || exit 1
        shift
        "$REAL_DOTFILES_DIR/bin/dots" "$@" >"$PROFILE_STDOUT" 2>"$PROFILE_STDERR"
    ' _ "$cwd" "$@"
}

_assert_streams_and_status() {
    [ "$status" -eq "$CHEESE_STATUS" ]
    [ "$(cat "$PROFILE_STDOUT")" = "engine stdout" ]
    [ "$(cat "$PROFILE_STDERR")" = "engine stderr" ]
}

_assert_argv() {
    local expected="$TEST_ROOT/expected"
    printf '%s\n' "$@" >"$expected"
    cmp -s "$expected" "$CHEESE_ARGS"
}

@test "list receives the explicit source root after caller arguments" {
    _run_profile profile list --format json
    _assert_streams_and_status
    _assert_argv profile list --format json --source-root "$DOTFILES_DIR"
}

@test "describe receives the explicit source root after caller arguments" {
    _run_profile profile describe demo --verbose
    _assert_streams_and_status
    _assert_argv profile describe demo --verbose --source-root "$DOTFILES_DIR"
}

@test "compile receives the explicit source root without reordering caller options" {
    _run_profile profile compile demo --baseline /baseline --output /publication
    _assert_streams_and_status
    _assert_argv \
        profile compile demo --baseline /baseline --output /publication \
        --source-root "$DOTFILES_DIR"
}

@test "launch inserts the explicit source root immediately before passthrough args" {
    _run_profile profile launch claude demo -- --resume "two words" --model opus
    _assert_streams_and_status
    _assert_argv \
        profile launch claude demo --source-root "$DOTFILES_DIR" -- \
        --resume "two words" --model opus
}

@test "launch appends the explicit source root when no passthrough separator exists" {
    _run_profile profile launch codex demo --resume
    _assert_streams_and_status
    _assert_argv profile launch codex demo --resume --source-root "$DOTFILES_DIR"
}

@test "apply forwards the manifest and state without a source root" {
    _run_profile profile apply /publication/manifest.json --state /state.json
    _assert_streams_and_status
    _assert_argv profile apply /publication/manifest.json --state /state.json
}

@test "permissions receives only the explicit project root" {
    local project_root="$TEST_ROOT/project root"
    mkdir -p "$project_root"

    _run_profile_from "$project_root" profile permissions --local --harness claude
    _assert_streams_and_status
    _assert_argv \
        profile permissions --local --harness claude \
        --project-root "$project_root"
}
