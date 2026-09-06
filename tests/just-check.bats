#!/usr/bin/env bats
# Regression tests for the read-only repository verification gate.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
FIXTURE_DIR=

setup() {
    FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/just-check.XXXXXX")"
}

teardown() {
    rm -rf "$FIXTURE_DIR"
}

run_markdownlint() {
    local root="$1"
    (
        cd "$root" || exit
        markdownlint-cli2 --config "$DOTFILES_DIR/.markdownlint-cli2.yaml" '**/*.md'
    )
}

@test "just check uses read-only lint and test legs" {
    run just --justfile "$DOTFILES_DIR/justfile" --dry-run check
    [[ "$status" -eq 0 ]]
    [[ "$output" != *"lint-fix"* ]]
    [[ "$output" != *"--fix"* ]]

    for leg in lint-shell lint-python lint-js lint-markdown test-python smoke test; do
        [[ "$output" == *"$leg"* ]]
    done

    run just --justfile "$DOTFILES_DIR/justfile" --dry-run lint-python
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"ruff format --check"* ]]

    run just --justfile "$DOTFILES_DIR/justfile" --dry-run lint-fix
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--fix"* ]]
}

@test "markdown lint ignores nested worktrees and preserves their Markdown" {
    local claude_fixture="$FIXTURE_DIR/.claude/worktrees/fixture"
    local dotfiles_fixture="$FIXTURE_DIR/.worktrees/fixture"
    mkdir -p "$claude_fixture" "$dotfiles_fixture"

    printf '# Fixture\ntext\n- item\n' > "$claude_fixture/README.md"
    printf '# Fixture\ntext\n- item\n' > "$dotfiles_fixture/README.md"
    local claude_before dotfiles_before
    claude_before="$(<"$claude_fixture/README.md")"
    dotfiles_before="$(<"$dotfiles_fixture/README.md")"

    run run_markdownlint "$FIXTURE_DIR"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"0 issues"* ]]
    [[ "$(cat "$claude_fixture/README.md")" == "$claude_before" ]]
    [[ "$(cat "$dotfiles_fixture/README.md")" == "$dotfiles_before" ]]
}

@test "markdown lint still rejects malformed canonical source Markdown" {
    mkdir -p "$FIXTURE_DIR/docs"
    printf '# Canonical\ntext\n- item\n' > "$FIXTURE_DIR/docs/canonical.md"

    run run_markdownlint "$FIXTURE_DIR"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"canonical.md"* ]]
    [[ "$output" == *"error"* ]]
}
