#!/usr/bin/env bats
#
# Tests for claude/lib/skills-sync.sh: sync_skills_per_subdir.
#
# The function symlinks each subdirectory of <source_dir> into <target_dir>:
#   - migrates a legacy directory-symlink at <target_dir> to a real dir
#   - preserves real directories already present (gh-installed skills)
#   - cleans up stale symlinks pointing at skills no longer in source
#
# We source the lib directly (no top-level side effects) and exercise it
# against scratch directories under $TEST_HOME.

# shellcheck disable=SC1090,SC2317

load test_helper

SKILLS_SYNC_LIB="$REAL_DOTFILES_DIR/claude/lib/skills-sync.sh"

setup() {
    setup_test_env

    export SRC="$TEST_HOME/dotfiles/skills"
    export DST="$TEST_HOME/.claude/skills"
    mkdir -p "$SRC" "$(dirname "$DST")"

    # shellcheck source=/dev/null
    source "$SKILLS_SYNC_LIB"
}

teardown() { teardown_test_env; }

# Make a fake skill directory under $SRC.
make_source_skill() {
    local name="$1"
    mkdir -p "$SRC/$name"
    printf '# %s\n' "$name" > "$SRC/$name/SKILL.md"
}

# ─── happy path ────────────────────────────────────────────────────────

@test "sync_skills_per_subdir: missing source dir is a no-op (returns 0)" {
    rm -rf "$SRC"
    [[ ! -d "$SRC" ]]

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    [[ ! -e "$DST" ]]
}

@test "sync_skills_per_subdir: empty source creates target dir but no symlinks" {
    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    [[ -d "$DST" ]]
    [[ ! -L "$DST" ]]

    # No entries inside
    run bash -c "ls -A '$DST' | wc -l | tr -d ' '"
    assert_success
    [[ "$output" == "0" ]]
}

@test "sync_skills_per_subdir: each subdir of source becomes a symlink in target" {
    make_source_skill commit
    make_source_skill de-slop
    make_source_skill diff

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success

    for name in commit de-slop diff; do
        assert_symlink "$DST/$name" "$SRC/$name"
        # Symlink resolves to a readable file
        [[ -f "$DST/$name/SKILL.md" ]]
    done
}

@test "sync_skills_per_subdir: ignores plain files inside source (only symlinks dirs)" {
    make_source_skill commit
    printf 'README\n' > "$SRC/README.md"

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success

    assert_symlink "$DST/commit" "$SRC/commit"
    [[ ! -e "$DST/README.md" ]]
}

# ─── idempotence ───────────────────────────────────────────────────────

@test "sync_skills_per_subdir: re-running is idempotent (refreshes existing symlinks)" {
    make_source_skill commit

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    assert_symlink "$DST/commit" "$SRC/commit"

    # Run again. Symlink should still point to the same target, no error.
    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    assert_symlink "$DST/commit" "$SRC/commit"
}

# ─── coexistence with gh-installed real directories ────────────────────

@test "sync_skills_per_subdir: real directory at target name is preserved with WARN" {
    # Pretend `gh skill install` created a real dir for the same name.
    make_source_skill age
    mkdir -p "$DST"
    mkdir -p "$DST/age"
    printf 'gh-installed\n' > "$DST/age/marker.txt"

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    assert_output_contains "WARN: $DST/age is a real directory"

    # Real dir untouched, no symlink created
    [[ -d "$DST/age" ]]
    [[ ! -L "$DST/age" ]]
    [[ -f "$DST/age/marker.txt" ]]
}

@test "sync_skills_per_subdir: real and dotfiles skills coexist alongside each other" {
    make_source_skill commit
    make_source_skill diff
    mkdir -p "$DST/external-installed"
    printf 'external\n' > "$DST/external-installed/SKILL.md"

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success

    assert_symlink "$DST/commit" "$SRC/commit"
    assert_symlink "$DST/diff" "$SRC/diff"
    [[ -d "$DST/external-installed" ]]
    [[ ! -L "$DST/external-installed" ]]
    [[ -f "$DST/external-installed/SKILL.md" ]]
}

# ─── stale symlink cleanup ─────────────────────────────────────────────

@test "sync_skills_per_subdir: removes dangling symlink when skill is deleted from source" {
    make_source_skill commit
    make_source_skill diff

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    assert_symlink "$DST/commit" "$SRC/commit"
    assert_symlink "$DST/diff" "$SRC/diff"

    # Delete one skill from source and re-run
    rm -rf "$SRC/diff"

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    assert_output_contains "Removed stale skill symlink: diff"

    assert_symlink "$DST/commit" "$SRC/commit"
    [[ ! -e "$DST/diff" ]]
    [[ ! -L "$DST/diff" ]]
}

@test "sync_skills_per_subdir: does not touch non-symlink entries during stale cleanup" {
    make_source_skill commit
    mkdir -p "$DST/external-installed"
    printf 'real\n' > "$DST/external-installed/SKILL.md"

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success

    [[ -d "$DST/external-installed" ]]
    [[ ! -L "$DST/external-installed" ]]
    [[ -f "$DST/external-installed/SKILL.md" ]]
}

# ─── legacy directory-symlink migration ────────────────────────────────

@test "sync_skills_per_subdir: migrates legacy directory symlink to real dir + per-skill symlinks" {
    # Old layout: ~/.claude/skills was a symlink to dotfiles/claude/skills/.
    rm -rf "$DST"
    ln -s "$SRC" "$DST"
    [[ -L "$DST" ]]

    make_source_skill commit
    make_source_skill diff

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    assert_output_contains "Migrated $DST from directory symlink to per-skill symlinks"

    # Now a real directory containing per-skill symlinks
    [[ -d "$DST" ]]
    [[ ! -L "$DST" ]]
    assert_symlink "$DST/commit" "$SRC/commit"
    assert_symlink "$DST/diff" "$SRC/diff"
}

@test "sync_skills_per_subdir: does not crash when source equals target ancestor (post-migration safety)" {
    # After migration, target is real and source is unchanged. Sanity check
    # that running once more from this state stays idempotent.
    make_source_skill commit
    rm -rf "$DST"
    ln -s "$SRC" "$DST"

    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success
    run sync_skills_per_subdir "$SRC" "$DST"
    assert_success

    [[ -d "$DST" ]]
    [[ ! -L "$DST" ]]
    assert_symlink "$DST/commit" "$SRC/commit"
}
