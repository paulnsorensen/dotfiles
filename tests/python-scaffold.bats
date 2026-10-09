#!/usr/bin/env bats
#
# Tests for skills/python-scaffold.
#
# Static tests always run. The end-to-end tests render the assets into fresh
# `uv init` projects and run the real gates. They download the dev tools, so
# they run only with PYTHON_SCAFFOLD_E2E=1.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SKILL_DIR="$REPO_ROOT/skills/python-scaffold"
    ASSETS="$SKILL_DIR/assets"
}

frontmatter() {
    awk '/^---/{c++; if(c==2)exit; if(c==1)next} c==1{print}' "$1"
}

@test "python-scaffold is user-invoked only in Claude and Codex" {
    local fm
    fm="$(frontmatter "$SKILL_DIR/SKILL.md")"
    [[ "$(echo "$fm" | yq -r '.name')" == "python-scaffold" ]]
    [[ "$(echo "$fm" | yq -r '."disable-model-invocation"')" == "true" ]]
    [[ "$(echo "$fm" | yq -r '.model // ""')" == "" ]]
    [[ "$(yq -r '.policy.allow_implicit_invocation' "$SKILL_DIR/agents/openai.yaml")" == "false" ]]
}

@test "SKILL.md links every asset, and every link resolves" {
    local link file
    while IFS= read -r link; do
        [[ -f "$SKILL_DIR/$link" ]] || { echo "broken link: $link" >&2; return 1; }
    done < <(grep -oE '\]\((assets|references)/[^)]+\)' "$SKILL_DIR/SKILL.md" | sed -E 's/^\]\(|\)$//g')
    for file in "$ASSETS"/*; do
        grep -qF "](assets/${file##*/})" "$SKILL_DIR/SKILL.md" \
            || { echo "unlinked asset: ${file##*/}" >&2; return 1; }
    done
}

@test "assets use only the three documented placeholders" {
    local found
    found="$(grep -rhoE '__[A-Z][A-Z_]*__' "$ASSETS" | sort -u | tr '\n' ' ')"
    [[ "$found" == "__PACKAGE__ __PROJECT__ __PYTHON__ " ]] || { echo "found: $found" >&2; return 1; }
}

@test "instruction assets carry template names so harnesses do not load them" {
    [[ -z "$(find "$SKILL_DIR" -mindepth 2 \( -name AGENTS.md -o -name CLAUDE.md -o -name SKILL.md \))" ]]
    grep -qxF '@AGENTS.md' "$ASSETS/CLAUDE.template.md"
}

@test "pyproject fragment keeps the checker defaults" {
    local json
    json="$(yq -p toml -o json '.tool' "$ASSETS/pyproject-tools.toml")"
    [[ "$(echo "$json" | yq -r '.basedpyright.typeCheckingMode')" == "recommended" ]]
    [[ "$(echo "$json" | yq -r '.vulture.min_confidence')" == "60" ]]
    [[ "$(echo "$json" | yq -r '.vulture.paths | join(" ")')" == "src vulture_whitelist.py" ]]
    [[ "$(echo "$json" | yq -r '.pytest.strict')" == "true" ]]
}

@test "CI workflow pins every action to a full SHA and drops credentials" {
    local uses
    while IFS= read -r uses; do
        [[ "$uses" =~ @[0-9a-f]{40}$ ]] || { echo "unpinned: $uses" >&2; return 1; }
    done < <(yq -r '.jobs[].steps[].uses | select(. != null)' "$ASSETS/ci.yml")
    [[ "$(yq -r '.permissions.contents' "$ASSETS/ci.yml")" == "read" ]]
    [[ "$(yq -r '.jobs.check.steps[0].with."persist-credentials"' "$ASSETS/ci.yml")" == "false" ]]
    [[ "$(yq -r '.jobs.check.steps[-1].run' "$ASSETS/ci.yml")" == "just ci" ]]
}

# render <asset> <project> <package> <dest>
render() {
    mkdir -p "$(dirname "$4")"
    sed -e "s/__PROJECT__/$2/g; s/__PACKAGE__/$3/g; s/__PYTHON__/3.12/g" "$ASSETS/$1" > "$4"
}

# scaffold <app|lib>: run the skill flow in $BATS_TEST_TMPDIR/demo-<mode>.
scaffold() {
    local mode="$1" project="demo-$1" package="demo_$1"
    DEMO="$BATS_TEST_TMPDIR/$project"
    if [[ "$mode" == lib ]]; then
        uv init -q --lib --python 3.12 "$DEMO"
    else
        uv init -q --package --python 3.12 "$DEMO"
    fi
    cd "$DEMO" || return 1
    printf '\n' >> pyproject.toml
    render pyproject-tools.toml "$project" "$package" fragment.toml
    cat fragment.toml >> pyproject.toml && rm fragment.toml
    render justfile "$project" "$package" justfile
    render pre-commit-config.yaml "$project" "$package" .pre-commit-config.yaml
    render ci.yml "$project" "$package" .github/workflows/ci.yml
    render AGENTS.template.md "$project" "$package" AGENTS.md
    render CLAUDE.template.md "$project" "$package" CLAUDE.md
    render python-authoring.template.md "$project" "$package" .agents/skills/python-authoring/SKILL.md
    mkdir -p .claude/skills tests
    ln -s ../../.agents/skills/python-authoring .claude/skills/python-authoring
    render vulture_whitelist.py "$project" "$package" vulture_whitelist.py
    if [[ "$mode" == lib ]]; then
        sed -i.bak 's/^main  # .*/hello  # public API/' vulture_whitelist.py && rm vulture_whitelist.py.bak
        printf 'from demo_lib import hello\n\n\ndef test_hello_names_the_package() -> None:\n    assert hello() == "Hello from demo-lib!"\n' > tests/test_hello.py
    else
        printf 'import pytest\n\nfrom demo_app import main\n\n\ndef test_main_greets(capsys: pytest.CaptureFixture[str]) -> None:\n    main()\n    assert capsys.readouterr().out == "Hello from demo-app!\\n"\n' > tests/test_main.py
    fi
    uv add -q --dev basedpyright pytest ruff vulture
    git add -A
    git -c user.name=scaffold -c user.email=scaffold@example.invalid commit -qm scaffold
}

require_e2e() {
    [[ "${PYTHON_SCAFFOLD_E2E:-}" == 1 ]] || skip "set PYTHON_SCAFFOLD_E2E=1 to run the networked scaffold test"
    command -v uv >/dev/null || skip "uv not installed"
    command -v just >/dev/null || skip "just not installed"
}

@test "e2e: scaffolded app and lib pass the gates with no fixes needed" {
    require_e2e
    local mode
    for mode in app lib; do
        scaffold "$mode"
        run just check
        [[ "$status" -eq 0 ]] || { echo "$mode check: $output" >&2; return 1; }
        [[ -z "$(git status --porcelain)" ]] || { git status --porcelain >&2; return 1; }
        run just ci
        [[ "$status" -eq 0 ]] || { echo "$mode ci: $output" >&2; return 1; }
        run grep -rlE '__(PROJECT|PACKAGE|PYTHON)__' --exclude-dir=.venv .
        [[ "$status" -eq 1 ]] || { echo "placeholders left: $output" >&2; return 1; }
    done
}

@test "e2e: the gate fails on dead code, a missing annotation, and an unknown marker" {
    require_e2e
    scaffold app
    printf '\n\ndef unused_helper() -> int:\n    return 1\n' >> src/demo_app/__init__.py
    run just deadcode
    [[ "$status" -ne 0 && "$output" == *"unused function 'unused_helper'"* ]] \
        || { echo "$output" >&2; return 1; }
    git checkout -q -- src
    printf '\n\ndef echo(value):\n    return value\n' >> src/demo_app/__init__.py
    run just typecheck
    [[ "$status" -ne 0 && "$output" == *"reportMissingParameterType"* ]] \
        || { echo "$output" >&2; return 1; }
    git checkout -q -- src
    printf 'import pytest\n\n\n@pytest.mark.unregistered\ndef test_marked() -> None:\n    pass\n' > tests/test_marker.py
    run just test
    [[ "$status" -ne 0 && "$output" == *"'unregistered' not found in \`markers\`"* ]] \
        || { echo "$output" >&2; return 1; }
}
