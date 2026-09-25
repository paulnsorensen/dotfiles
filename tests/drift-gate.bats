#!/usr/bin/env bats
# Unit tests for chezmoi/lib/drift-gate.sh, the shared unknown-key gate that
# the Claude, OMP, and Pi settings guards source.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export GATE="$REAL_DOTFILES_DIR/chezmoi/lib/drift-gate.sh"
}

teardown() { teardown_test_env; }

# gate FUNCTION ARGS... — run one drift-gate.sh function in POSIX sh.
gate() {
    # shellcheck disable=SC2016 # expands in the child shell
    run --separate-stderr sh -c '. "$GATE"; "$@"' _ "$@"
}

@test "drift_ignore_paths parses dot-paths and skips comments and blanks" {
    printf '# note\n\ntui\n  env.FOO  # trailing\n' > "$TEST_HOME/ignore.txt"
    gate drift_ignore_paths "$TEST_HOME/ignore.txt"
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<<"$output")" = '[["tui"],["env","FOO"]]' ]
}

@test "drift_ignore_paths gives an empty list for a missing file" {
    gate drift_ignore_paths "$TEST_HOME/absent.txt"
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<<"$output")" = '[]' ]
}

@test "drift_unknown ignores list indices, exempt prefixes, and extra known paths" {
    gate drift_unknown \
        '{"a":1,"list":[{"k":1},{"k":2}],"skip":{"x":1},"extra":1,"new":{"deep":null}}' \
        '{"a":0,"list":[{"k":0}]}' '[["skip"]]' '[["extra"]]'
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<<"$output")" = '[["new"],["new","deep"]]' ]
}

@test "drift_preserve keeps each outermost unknown path once" {
    gate drift_preserve '{"a":1,"new":{"deep":{"x":1}},"obj":{"n":true}}' \
        '{"a":0,"obj":{}}' '[["new"],["new","deep"],["new","deep","x"],["obj","n"]]'
    [ "$status" -eq 0 ]
    [ "$(jq -c '.doc' <<<"$output")" = '{"a":0,"obj":{"n":true},"new":{"deep":{"x":1}}}' ]
    [ "$(jq -c '.preserved' <<<"$output")" = '["new","obj.n"]' ]
    [ "$(jq -c '.dropped' <<<"$output")" = '[]' ]
}

@test "drift_preserve drops a path inside a list or under a repo-owned scalar" {
    gate drift_preserve '{"list":[{"x":1}],"s":{"y":2}}' '{"list":[],"s":"scalar"}' \
        '[["list","x"],["s","y"]]'
    [ "$status" -eq 0 ]
    [ "$(jq -c '.doc' <<<"$output")" = '{"list":[],"s":"scalar"}' ]
    [ "$(jq -c '.dropped' <<<"$output")" = '["list.x","s.y"]' ]
}

@test "drift_overlay_ignored fills unowned leaves and keeps repo-owned values" {
    gate drift_overlay_ignored '{"m":{"old":"live","new":"live"}}' '{"m":{"old":"repo"}}' '[["m"]]'
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<<"$output")" = '{"m":{"old":"repo","new":"live"}}' ]
}

@test "drift_report warns and records drift, then clears it when clean" {
    local state="$DOTFILES_STATE_DIR/harness-drift/demo"
    gate drift_report demo "Demo file" '{"preserved":["a.b"],"dropped":["l.x"]}' /src/registry.yaml
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"WARNING: Demo file"* ]]
    [[ "$stderr" == *"+ a.b"* && "$stderr" == *"- l.x"* && "$stderr" == *"/src/registry.yaml"* ]]
    [ "$(cat "$state")" = $'preserved a.b\ndropped l.x' ]

    gate drift_report demo "Demo file" '{"preserved":[],"dropped":[]}' /src/registry.yaml
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ ! -e "$state" ]
}

@test "drift_report never fails the guard when the state dir is unwritable" {
    printf 'file' > "$TEST_HOME/blocker"
    DOTFILES_STATE_DIR="$TEST_HOME/blocker" \
        gate drift_report demo "Demo file" '{"preserved":["a"],"dropped":[]}' /src
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"+ a"* ]]
    [[ "$stderr" == *"WARNING: could not persist drift state file: $TEST_HOME/blocker/harness-drift/demo"* ]]
}

@test "drift_report warns on stderr when it cannot remove a stale state file" {
    local state="$DOTFILES_STATE_DIR/harness-drift/demo"
    mkdir -p "$state"
    gate drift_report demo "Demo file" '{"preserved":[],"dropped":[]}' /src
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"WARNING: could not remove stale drift state file: $state"* ]]
}

@test "drift_report describes drop reason as list or owned-scalar" {
    gate drift_report demo "Demo file" \
        '{"preserved":[],"dropped":["l.x","s.y"],"dropReasons":{"l.x":"list","s.y":"owned-scalar"}}' /src
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"- l.x  (inside a managed list; live value not kept)"* ]]
    [[ "$stderr" == *"- s.y  (under a repo-owned value; live value not kept)"* ]]
}

@test "drift_overlay_ignored copies an owned empty object or array but not owned paths" {
    gate drift_overlay_ignored \
        '{"m":{"emptyObj":{},"emptyArr":[],"already":"live"}}' \
        '{"m":{"already":"repo"}}' '[["m"]]'
    [ "$status" -eq 0 ]
    [ "$(jq -c . <<<"$output")" = '{"m":{"already":"repo","emptyObj":{},"emptyArr":[]}}' ]
}

@test "drift_preserve records list vs owned-scalar drop reasons" {
    gate drift_preserve '{"list":[{"x":1}],"s":{"y":2},"new":1}' '{"list":[],"s":"scalar"}' \
        '[["list","x"],["s","y"],["new"]]'
    [ "$status" -eq 0 ]
    [ "$(jq -c '.dropReasons' <<<"$output")" = '{"list.x":"list","s.y":"owned-scalar"}' ]
    [ "$(jq -c '.preserved' <<<"$output")" = '["new"]' ]
}

@test "drift_state_dir and drift_state_file resolve under DOTFILES_STATE_DIR" {
    gate drift_state_dir
    [ "$status" -eq 0 ]
    [ "$output" = "$DOTFILES_STATE_DIR/harness-drift" ]

    gate drift_state_file demo
    [ "$status" -eq 0 ]
    [ "$output" = "$DOTFILES_STATE_DIR/harness-drift/demo" ]
}

@test "drift_print_recorded prints recorded files and sets the count" {
    mkdir -p "$DOTFILES_STATE_DIR/harness-drift"
    printf 'preserved a.b\n' > "$DOTFILES_STATE_DIR/harness-drift/demo"
    : > "$DOTFILES_STATE_DIR/harness-drift/empty"

    gate drift_print_recorded "  "
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unfolded harness settings in demo (kept or dropped; see below):"* ]]
    [[ "$output" == *"  preserved a.b"* ]]
    [[ "$output" != *"empty"* ]]
}

@test "drift_print_recorded returns 1 and sets zero count without recorded drift" {
    gate drift_print_recorded
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    # shellcheck disable=SC2016 # expands in the child shell
    run --separate-stderr sh -c '. "$GATE"; drift_print_recorded >/dev/null; printf "%s" "$DRIFT_RECORDED_COUNT"'
    [ "$output" = "0" ]
}
