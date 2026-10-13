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
    [[ "$output" == *"tests/check-affected.sh"* ]]

    run just --justfile "$DOTFILES_DIR/justfile" --dry-run check-all
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"tests/check-affected.sh --all"* ]]

    # Every leg the gate can select stays read-only.
    run "$DOTFILES_DIR/tests/check-affected.sh" --all --plan
    [[ "$status" -eq 0 ]]
    local plan="$output"
    for leg in lint-shell lint-python lint-js lint-markdown test-python smoke test; do
        [[ "$plan" == *"$leg"* ]]
        run just --justfile "$DOTFILES_DIR/justfile" --dry-run "$leg"
        [[ "$status" -eq 0 ]]
        [[ "$output" != *"--fix"* ]]
    done

    run just --justfile "$DOTFILES_DIR/justfile" --dry-run lint-python
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"ruff format --check"* ]]

    run just --justfile "$DOTFILES_DIR/justfile" --dry-run lint-fix
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--fix"* ]]
}

@test "Python gate retains automatic pytest workers" {
    run just --justfile "$DOTFILES_DIR/justfile" --dry-run test-python
    [ "$status" -eq 0 ]
    [[ "$output" == *"uv run pytest -n auto"* ]] || return 1
}

@test "Bats wrapper keeps CPU workers and discovers Python suite wrappers" {
    mkdir -p "$FIXTURE_DIR/bin" "$FIXTURE_DIR/home"
    cat > "$FIXTURE_DIR/bin/bats" <<'BATS'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$BATS_ARGS"
printf '1..1\nok 1 fixture\n'
BATS
    cat > "$FIXTURE_DIR/bin/nproc" <<'NPROC'
#!/usr/bin/env bash
printf '7\n'
NPROC
    chmod +x "$FIXTURE_DIR/bin/bats" "$FIXTURE_DIR/bin/nproc"
    export BATS_ARGS="$FIXTURE_DIR/bats.args"

    run env HOME="$FIXTURE_DIR/home" PATH="$FIXTURE_DIR/bin:$PATH" bash "$DOTFILES_DIR/tests/run-tests.sh"
    [ "$status" -eq 0 ]
    local args
    args="$(<"$BATS_ARGS")"
    [[ "$args" == *"--jobs 7"* ]] || return 1
    local wrapper
    for wrapper in check-affected.bats ci-optimize.bats hill-climb.bats junit-to-weights.bats; do
        [[ "$args" == *"$wrapper"* ]] || return 1
    done
}

make_lint_stub() {
    local name="$1"
    cat > "$FIXTURE_DIR/$name" <<'STUB'
#!/usr/bin/env bash
lane="${0##*/}"
if mkdir "$LINT_SYNC/$lane.claim" 2>/dev/null; then
    : > "$LINT_SYNC/$lane"
    for ((i = 0; i < 300; i++)); do
        count=$(find "$LINT_SYNC" -type f | wc -l)
        (( count == 4 )) && break
        sleep 0.1
    done
    if (( count != 4 )); then
        printf 'lint barrier timed out: %s\n' "$lane" >&2
        exit 99
    fi
fi
if [[ "$lane" == "$FAIL_LANE" ]]; then
    printf 'injected lint failure: %s\n' "$lane" >&2
    exit 23
fi
STUB
    chmod +x "$FIXTURE_DIR/$name"
}

@test "just lint runs all four read-only lanes together and reports each failure" {
    local lane
    for lane in shellcheck ruff eslint markdownlint-cli2; do
        make_lint_stub "$lane"
    done
    export LINT_SYNC="$FIXTURE_DIR/sync"
    mkdir -p "$LINT_SYNC"
    export PATH="$FIXTURE_DIR:$PATH"
    export FAIL_LANE=

    run just --justfile "$DOTFILES_DIR/justfile" lint
    [ "$status" -eq 0 ]
    for lane in shellcheck ruff eslint markdownlint-cli2; do
        [ -f "$LINT_SYNC/$lane" ] || return 1
    done

    for FAIL_LANE in shellcheck ruff eslint markdownlint-cli2; do
        rm -rf "${LINT_SYNC:?}/"*
        run just --justfile "$DOTFILES_DIR/justfile" lint
        [ "$status" -ne 0 ]
        [[ "$output" == *"injected lint failure: $FAIL_LANE"* ]] || return 1
        [[ "$output" != *"lint barrier timed out"* ]] || return 1
        for lane in shellcheck ruff eslint markdownlint-cli2; do
            [ -f "$LINT_SYNC/$lane" ] || return 1
        done
    done
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

@test "markdown lint ignores generated OMP skills but checks their canonical source" {
    local generated="$FIXTURE_DIR/chezmoi/dot_omp/private_agent/exact_skills/exact_fixture"
    local canonical="$FIXTURE_DIR/skills/fixture"
    local malformed=$'# Fixture\ntext\n- item'
    mkdir -p "$generated" "$canonical"
    printf '%s\n' "$malformed" > "$generated/SKILL.md"

    run run_markdownlint "$FIXTURE_DIR"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"0 issues"* ]]
    [[ "$(<"$generated/SKILL.md")" == "$malformed" ]]

    printf '%s\n' "$malformed" > "$canonical/SKILL.md"
    run run_markdownlint "$FIXTURE_DIR"
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"skills/fixture/SKILL.md"* ]]
    [[ "$output" == *"error MD032"* ]]
    [[ "$(<"$canonical/SKILL.md")" == "$malformed" ]]
}
