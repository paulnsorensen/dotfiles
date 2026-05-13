#!/usr/bin/env bats
#
# Tests for skills-install/install-local.sh.
#
# The installer copies each subdirectory of <source_dir> into <target_dir>
# as real files (not symlinks), so gh-installed skills can coexist alongside
# dotfiles-owned ones. Ownership is tracked via <target_dir>/.dotfiles-managed
# so the installer never deletes a skill it didn't put there.

# shellcheck disable=SC1090,SC2317

load test_helper

INSTALL_SCRIPT="$REAL_DOTFILES_DIR/skills-install/install-local.sh"

setup() {
    setup_test_env

    export SRC="$TEST_HOME/dotfiles/skills"
    export DST="$TEST_HOME/.claude/skills"
    mkdir -p "$SRC" "$(dirname "$DST")"
}

teardown() { teardown_test_env; }

make_source_skill() {
    local name="$1"
    mkdir -p "$SRC/$name"
    printf '# %s\n' "$name" > "$SRC/$name/SKILL.md"
}

@test "install-local: missing source dir exits non-zero" {
    rm -rf "$SRC"
    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 1 ]]
}

@test "install-local: wrong arg count exits 2" {
    run "$INSTALL_SCRIPT" "$SRC"
    [[ "$status" -eq 2 ]]
}

@test "install-local: empty source creates target dir + empty manifest" {
    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ -d "$DST" ]]
    [[ -f "$DST/.dotfiles-managed" ]]
    [[ ! -s "$DST/.dotfiles-managed" ]]
}

@test "install-local: each source skill becomes a real directory in target" {
    make_source_skill commit
    make_source_skill diff

    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]

    [[ -d "$DST/commit" && ! -L "$DST/commit" ]]
    [[ -d "$DST/diff" && ! -L "$DST/diff" ]]
    [[ -f "$DST/commit/SKILL.md" ]]
    grep -Fxq commit "$DST/.dotfiles-managed"
    grep -Fxq diff   "$DST/.dotfiles-managed"
}

@test "install-local: copies real files (target survives source deletion)" {
    make_source_skill commit
    "$INSTALL_SCRIPT" "$SRC" "$DST"

    rm -rf "$SRC/commit"
    [[ -f "$DST/commit/SKILL.md" ]]
    [[ "$(cat "$DST/commit/SKILL.md")" == "# commit" ]]
}

@test "install-local: idempotent — re-running refreshes content without churn" {
    make_source_skill commit
    "$INSTALL_SCRIPT" "$SRC" "$DST"

    printf '# updated\n' > "$SRC/commit/SKILL.md"
    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ "$(cat "$DST/commit/SKILL.md")" == "# updated" ]]
}

@test "install-local: unmanaged real directory at target is preserved with WARN" {
    mkdir -p "$DST"
    mkdir -p "$DST/gh-installed"
    printf 'external\n' > "$DST/gh-installed/SKILL.md"
    make_source_skill commit

    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ -f "$DST/gh-installed/SKILL.md" ]]
    [[ "$(cat "$DST/gh-installed/SKILL.md")" == "external" ]]
    [[ -d "$DST/commit" ]]
}

@test "install-local: name collision (gh-installed skill named like dotfiles skill) is skipped" {
    mkdir -p "$DST"
    mkdir -p "$DST/commit"
    printf 'external commit\n' > "$DST/commit/SKILL.md"

    make_source_skill commit

    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ "${output}" == *"WARN"*"unmanaged"* ]]
    [[ "$(cat "$DST/commit/SKILL.md")" == "external commit" ]]

    # The skipped name must NOT be recorded as dotfiles-managed — otherwise a
    # future run with the source skill removed would delete the gh-installed
    # directory we just preserved.
    ! grep -Fxq commit "$DST/.dotfiles-managed"
}

@test "install-local: collision-skipped skill survives source removal" {
    # Regression test for the manifest bug: even after the source skill is
    # deleted, the collided external dir must remain because it was never
    # claimed in the manifest.
    mkdir -p "$DST/commit"
    printf 'external commit\n' > "$DST/commit/SKILL.md"
    make_source_skill commit

    "$INSTALL_SCRIPT" "$SRC" "$DST"

    rm -rf "$SRC/commit"
    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ -f "$DST/commit/SKILL.md" ]]
    [[ "$(cat "$DST/commit/SKILL.md")" == "external commit" ]]
}

@test "install-local: skill dropped from source is removed from target" {
    make_source_skill commit
    make_source_skill diff
    "$INSTALL_SCRIPT" "$SRC" "$DST"

    rm -rf "$SRC/diff"
    run "$INSTALL_SCRIPT" "$SRC" "$DST"

    [[ "$status" -eq 0 ]]
    [[ -d "$DST/commit" ]]
    [[ ! -e "$DST/diff" ]]
    grep -Fxq commit "$DST/.dotfiles-managed"
    ! grep -Fxq diff "$DST/.dotfiles-managed"
}

@test "install-local: dangling symlinks at target are cleaned up" {
    mkdir -p "$DST"
    ln -s "$SRC/nonexistent" "$DST/stale"
    make_source_skill commit

    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ ! -e "$DST/stale" && ! -L "$DST/stale" ]]
}

@test "install-local: legacy per-skill symlink at target is replaced by a real copy" {
    make_source_skill commit
    mkdir -p "$DST"
    ln -s "$SRC/commit" "$DST/commit"

    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]

    [[ -d "$DST/commit" && ! -L "$DST/commit" ]]
    [[ "$(cat "$DST/commit/SKILL.md")" == "# commit" ]]

    rm -rf "$SRC/commit"
    [[ -f "$DST/commit/SKILL.md" ]]
}

@test "install-local: ignores plain files in source (only directories are skills)" {
    make_source_skill commit
    printf 'not a skill\n' > "$SRC/README.md"

    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ -d "$DST/commit" ]]
    [[ ! -e "$DST/README.md" ]]
}

@test "install-local: nested files inside a skill are preserved" {
    mkdir -p "$SRC/lint/references"
    printf '# lint\n' > "$SRC/lint/SKILL.md"
    printf 'rust\n' > "$SRC/lint/references/rust.md"

    run "$INSTALL_SCRIPT" "$SRC" "$DST"
    [[ "$status" -eq 0 ]]
    [[ -f "$DST/lint/SKILL.md" ]]
    [[ -f "$DST/lint/references/rust.md" ]]
}
