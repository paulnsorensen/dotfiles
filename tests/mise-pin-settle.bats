#!/usr/bin/env bats
# Unit tests for settle_mise_pin_bump in packages/lib-mise-pins.sh
#
# `dots sync` publishes a mise pin bump as an auto-merge PR and leaves the
# bumped manifest dirty. After the PR merges, the next `dots sync` must
# fast-forward main so the checkout is clean, and must never lose local work.

load test_helper
bats_require_minimum_version 1.5.0

LIB="$REAL_DOTFILES_DIR/packages/lib-mise-pins.sh"
BUMPED=$'[tools]\n"aqua:example/tool" = "2.0.0"\n'

# shellcheck disable=SC2329  # log_* stubs run inside the sourced lib.
setup() {
    setup_test_env
    log_info() { echo "INFO $1"; }
    log_success() { echo "OK $1"; }
    log_warning() { echo "WARN $1" >&2; }
    log_error() { echo "ERR $1" >&2; }
    # shellcheck disable=SC1090
    source "$LIB"

    export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
    export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
    ORIGIN="$TEST_HOME/origin.git"
    WORK="$TEST_HOME/work"
    UPSTREAM="$TEST_HOME/upstream"
    MANIFEST="$WORK/mise-config.toml"

    git init -q --bare -b main "$ORIGIN"
    git init -q -b main "$WORK"
    printf '[tools]\n' > "$MANIFEST"
    printf 'x\n' > "$WORK/other.txt"
    git -C "$WORK" add .
    git -C "$WORK" commit -qm init
    git -C "$WORK" remote add origin "$ORIGIN"
    git -C "$WORK" push -q -u origin main
    git clone -q "$ORIGIN" "$UPSTREAM"
}

teardown() {
    teardown_test_env
}

# Commit <content> to <file> on origin/main, as a merged PR would.
land_upstream() {
    printf '%s' "$2" > "$UPSTREAM/$1"
    git -C "$UPSTREAM" add -- "$1"
    git -C "$UPSTREAM" commit -qm "land $1"
    git -C "$UPSTREAM" push -q origin main
}

# The state publish_mise_pin_bump leaves: the bump sits dirty in the checkout.
dirty_bump() {
    printf '%s' "$BUMPED" > "$MANIFEST"
}

# Push the bump to the pin branch off the current origin/main, as publish does.
push_pin_branch() {
    git -C "$UPSTREAM" checkout -q -b chore/mise-pins
    printf '%s' "$BUMPED" > "$UPSTREAM/mise-config.toml"
    git -C "$UPSTREAM" commit -qam "chore(mise): bump pins"
    git -C "$UPSTREAM" push -q origin chore/mise-pins
    git -C "$UPSTREAM" checkout -q main
}

@test "a merged pin PR fast-forwards main and cleans the checkout" {
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"
    land_upstream later.txt $'later\n'

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"main fast-forwarded to origin/main"* ]]
    [[ -z "$(git -C "$WORK" status --porcelain)" ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$(git -C "$WORK" rev-parse origin/main)" ]]
    [[ -f "$WORK/later.txt" ]]
}

@test "an open pin PR leaves the checkout as it was" {
    push_pin_branch
    dirty_bump
    local head
    head="$(git -C "$WORK" rev-parse HEAD)"
    land_upstream other.txt $'y\n'

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ -z "$output" ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$head" ]]
    [[ "$(git -C "$WORK" status --porcelain)" == " M mise-config.toml" ]]
}

@test "a clean manifest returns before any fetch" {
    git -C "$WORK" remote set-url origin "$TEST_HOME/no-such-remote.git"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ -z "$output" ]]
}

@test "a checkout off main is left alone" {
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"
    git -C "$WORK" checkout -q -b feature

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ -z "$output" ]]
    [[ "$(git -C "$WORK" branch --show-current)" == "feature" ]]
    [[ "$(git -C "$WORK" status --porcelain)" == " M mise-config.toml" ]]
}

@test "local commits that origin/main lacks block the fast-forward" {
    printf 'local\n' > "$WORK/local.txt"
    git -C "$WORK" add local.txt
    git -C "$WORK" commit -qm local
    local head
    head="$(git -C "$WORK" rev-parse HEAD)"
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"local main has commits origin/main lacks"* ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$head" ]]
    [[ "$(git -C "$WORK" status --porcelain)" == " M mise-config.toml" ]]
}

@test "a local edit that the fast-forward would overwrite blocks it and stays" {
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"
    land_upstream other.txt $'upstream\n'
    printf 'mine\n' > "$WORK/other.txt"
    local head
    head="$(git -C "$WORK" rev-parse HEAD)"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"local edits block the fast-forward"* ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$head" ]]
    [[ "$(cat "$WORK/other.txt")" == "mine" ]]
    # The manifest is dirty again, not left staged.
    git -C "$WORK" diff --cached --quiet
    [[ "$(cat "$MANIFEST")" == "$(printf '%s' "$BUMPED")" ]]
}

@test "an unrelated local edit survives the fast-forward" {
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"
    printf 'mine\n' > "$WORK/other.txt"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"main fast-forwarded"* ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$(git -C "$WORK" rev-parse origin/main)" ]]
    [[ "$(git -C "$WORK" status --porcelain)" == " M other.txt" ]]
}

@test "a failed fetch warns and leaves the checkout as it was" {
    dirty_bump
    git -C "$WORK" remote set-url origin "$TEST_HOME/no-such-remote.git"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"fetch of origin/main failed"* ]]
    [[ "$(git -C "$WORK" status --porcelain)" == " M mise-config.toml" ]]
}

@test "a pin PR that origin/main moved past is dropped so main can fast-forward" {
    push_pin_branch
    dirty_bump
    land_upstream mise-config.toml $'[tools]\n"aqua:example/upstream" = "9.0.0"\n'

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"moved past the open mise pin PR"* ]]
    [[ -z "$(git -C "$WORK" status --porcelain)" ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$(git -C "$WORK" rev-parse origin/main)" ]]
    grep -q 'aqua:example/upstream' "$MANIFEST"
}

@test "a current pin PR keeps its bump in the checkout" {
    push_pin_branch
    dirty_bump
    land_upstream other.txt $'y\n'
    local head
    head="$(git -C "$WORK" rev-parse HEAD)"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ -z "$output" ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$head" ]]
    [[ "$(git -C "$WORK" status --porcelain)" == " M mise-config.toml" ]]
}

@test "a dropped stale bump comes back when local edits block the fast-forward" {
    push_pin_branch
    dirty_bump
    land_upstream mise-config.toml $'[tools]\n"aqua:example/upstream" = "9.0.0"\n'
    land_upstream other.txt $'upstream\n'
    printf 'mine\n' > "$WORK/other.txt"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"local edits block the fast-forward"* ]]
    git -C "$WORK" diff --cached --quiet
    [[ "$(cat "$MANIFEST")" == "$(printf '%s' "$BUMPED")" ]]
    [[ "$(cat "$WORK/other.txt")" == "mine" ]]
}

@test "a merged pin PR followed by an upstream manifest edit still settles" {
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"
    land_upstream mise-config.toml $'[tools]\n"aqua:example/upstream" = "9.0.0"\n'

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"edited the manifest since"* ]]
    [[ -z "$(git -C "$WORK" status --porcelain)" ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$(git -C "$WORK" rev-parse origin/main)" ]]
    grep -q 'aqua:example/upstream' "$MANIFEST"
}

@test "a manifest that matches no public pin bump warns and stays" {
    printf 'mine\n' > "$MANIFEST"
    land_upstream mise-config.toml "$BUMPED"
    local head
    head="$(git -C "$WORK" rev-parse HEAD)"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"matches no public mise pin bump"* ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$head" ]]
    [[ "$(cat "$MANIFEST")" == "mine" ]]
}

@test "a manifest the user staged is left alone" {
    dirty_bump
    git -C "$WORK" add mise-config.toml
    land_upstream mise-config.toml "$BUMPED"
    local head
    head="$(git -C "$WORK" rev-parse HEAD)"

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ -z "$output" ]]
    [[ "$(git -C "$WORK" rev-parse HEAD)" == "$head" ]]
    [[ "$(git -C "$WORK" status --porcelain)" == "M  mise-config.toml" ]]
}

@test "a staged unrelated edit survives the fast-forward" {
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"
    printf 'staged\n' > "$WORK/notes.txt"
    git -C "$WORK" add notes.txt

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ "$output" == *"main fast-forwarded"* ]]
    [[ "$(git -C "$WORK" status --porcelain)" == "A  notes.txt" ]]
}

@test "a detached HEAD is left alone" {
    dirty_bump
    land_upstream mise-config.toml "$BUMPED"
    git -C "$WORK" checkout -q --detach

    run settle_mise_pin_bump "$MANIFEST"
    assert_success
    [[ -z "$output" ]]
    [[ "$(git -C "$WORK" status --porcelain)" == " M mise-config.toml" ]]
}
