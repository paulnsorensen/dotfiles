#!/usr/bin/env bats
#
# Tests for chezmoi/lib/prune-stale-local-skills.sh and its run_once caller.
#
# The prune deletes a stale ap-era copy <target>/<name> only when the dotfiles
# source ships <name>, the copy is a real directory, .dotfiles-managed does not
# list it, and no `skills` CLI lockfile key has that basename.

# shellcheck disable=SC1003,SC1090,SC2016,SC2317

load test_helper

PRUNE_SCRIPT="$REAL_DOTFILES_DIR/chezmoi/lib/prune-stale-local-skills.sh"

setup() {
    setup_test_env

    export SRC="$TEST_HOME/dotfiles/skills"
    export DST="$TEST_HOME/.agents/skills"
    export LOCK="$TEST_HOME/.agents/.skill-lock.json"
    mkdir -p "$SRC" "$DST"
}

teardown() { teardown_test_env; }

make_source_skill() {
    mkdir -p "$SRC/$1"
    printf '# %s\n' "$1" > "$SRC/$1/SKILL.md"
}

make_target_copy() {
    mkdir -p "$DST/$1"
    printf 'ap copy of %s\n' "$1" > "$DST/$1/SKILL.md"
}

# Args: lockfile keys, e.g. `age` or `acme/age`. No args: empty skills map.
write_lock() {
    local entries="" key
    for key in "$@"; do
        entries+="${entries:+,}\"$key\":{\"source\":\"acme/repo\"}"
    done
    printf '{"version":3,"skills":{%s}}\n' "$entries" > "$LOCK"
}

run_prune() { run "$PRUNE_SCRIPT" "$SRC" "$DST" "$LOCK"; }

@test "prune-stale-local-skills: wrong arg count prints usage and exits 2" {
    run "$PRUNE_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 2 ]]
    assert_output_contains "Usage:"
}

@test "prune-stale-local-skills: missing source dir exits 1" {
    rm -rf "$SRC"
    run_prune
    [[ "$status" -eq 1 ]]
    assert_output_contains "source directory not found"
}

@test "prune-stale-local-skills: removes an unmanaged, unlocked copy that matches a source skill" {
    make_source_skill age
    make_target_copy age
    write_lock

    run_prune
    assert_success
    [[ "$output" == "  Removed stale local skill copy: $DST/age" ]]
    [[ ! -e "$DST/age" ]]
}

@test "prune-stale-local-skills: keeps a copy tracked by a bare lockfile key" {
    make_source_skill age
    make_target_copy age
    write_lock age

    run_prune
    assert_success
    [[ -z "$output" ]]
    [[ "$(cat "$DST/age/SKILL.md")" == "ap copy of age" ]]
}

@test "prune-stale-local-skills: keeps a copy tracked by an owner/name lockfile key" {
    make_source_skill age
    make_target_copy age
    write_lock "acme/age"

    run_prune
    assert_success
    [[ -z "$output" ]]
    [[ "$(cat "$DST/age/SKILL.md")" == "ap copy of age" ]]
}

@test "prune-stale-local-skills: keeps a copy listed in .dotfiles-managed" {
    make_source_skill age
    make_target_copy age
    printf 'age\n' > "$DST/.dotfiles-managed"
    write_lock

    run_prune
    assert_success
    [[ -z "$output" ]]
    [[ "$(cat "$DST/age/SKILL.md")" == "ap copy of age" ]]
    [[ "$(cat "$DST/.dotfiles-managed")" == "age" ]]
}

@test "prune-stale-local-skills: keeps a target dir with no matching source skill" {
    make_source_skill age
    make_target_copy gh-installed
    write_lock

    run_prune
    assert_success
    [[ -z "$output" ]]
    [[ "$(cat "$DST/gh-installed/SKILL.md")" == "ap copy of gh-installed" ]]
}

@test "prune-stale-local-skills: leaves a symlink alone" {
    make_source_skill age
    ln -s "$SRC/age" "$DST/age"
    write_lock

    run_prune
    assert_success
    [[ -z "$output" ]]
    [[ -L "$DST/age" ]]
    [[ "$(readlink "$DST/age")" == "$SRC/age" ]]
}

@test "prune-stale-local-skills: a missing lockfile means no locked names" {
    make_source_skill age
    make_target_copy age
    [[ ! -e "$LOCK" ]]

    run_prune
    assert_success
    [[ "$output" == "  Removed stale local skill copy: $DST/age" ]]
    [[ ! -e "$DST/age" ]]
}

@test "prune-stale-local-skills: a lockfile that does not parse aborts before any removal" {
    make_source_skill age
    make_target_copy age
    printf 'not json\n' > "$LOCK"

    run_prune
    [[ "$status" -eq 1 ]]
    assert_output_contains "could not parse lockfile"
    [[ "$(cat "$DST/age/SKILL.md")" == "ap copy of age" ]]
}

@test "prune-stale-local-skills: a missing target dir is a no-op" {
    make_source_skill age
    rm -rf "$DST"

    run_prune
    assert_success
    [[ -z "$output" ]]
    [[ ! -e "$DST" ]]
}

@test "prune-stale-local-skills: prints one line per removal and prunes only the stale names" {
    make_source_skill age
    make_source_skill cook
    make_source_skill press
    make_source_skill plate
    make_target_copy age      # stale: removed
    make_target_copy plate    # stale: removed
    make_target_copy cook     # in .dotfiles-managed: kept
    make_target_copy press    # lock-tracked: kept
    make_target_copy other    # not a source skill: kept
    printf 'cook\n' > "$DST/.dotfiles-managed"
    write_lock "acme/press"

    run_prune
    assert_success
    [[ "${#lines[@]}" -eq 2 ]]
    [[ "${lines[0]}" == "  Removed stale local skill copy: $DST/age" ]]
    [[ "${lines[1]}" == "  Removed stale local skill copy: $DST/plate" ]]
    [[ ! -e "$DST/age" ]]
    [[ ! -e "$DST/plate" ]]
    [[ -f "$DST/cook/SKILL.md" ]]
    [[ -f "$DST/press/SKILL.md" ]]
    [[ -f "$DST/other/SKILL.md" ]]
}

@test "run_once migrate-agents-skills: renders the prune call for ~/.agents/skills only" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/cz.toml"
    cat > "$cfg" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
TOML
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_once_before_migrate-agents-skills.sh.tmpl"
    run chezmoi --config "$cfg" --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl"
    [[ "$status" -eq 0 ]]
    ! grep -qF '{{' <<<"$output"
    grep -qF "SOURCE_DIR=\"$REAL_DOTFILES_DIR/chezmoi\"" <<<"$output"
    grep -qF '[[ -d "$DOTFILES_ROOT/skills" ]] || exit 0' <<<"$output"
    grep -qF '"$SOURCE_DIR/lib/prune-stale-local-skills.sh" \' <<<"$output"
    grep -qF '    "$DOTFILES_ROOT/skills" \' <<<"$output"
    grep -qF '    "$HOME/.agents/skills" \' <<<"$output"
    grep -qF '    "$HOME/.agents/.skill-lock.json"' <<<"$output"
    ! grep -qF '"$HOME/.cursor/skills"' <<<"$output"
}
