# dotfiles task runner

# list available recipes
default:
    @just --list

# run all linters
lint: lint-shell lint-python lint-js lint-markdown

# shellcheck on shell scripts: one process per file, fanned across all cores
lint-shell:
    #!/usr/bin/env bash
    set -uo pipefail
    jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    check() { xargs -P "$jobs" -n 1 shellcheck -x "$@"; }
    { find bin -type f; echo .sync; } | check -e SC1091 & bin=$!
    printf '%s\n' agents/mcp/sync.sh agents/hooks/sync.sh agents/hooks/lib.sh claude/plugins/sync.sh \
        claude/lib/sync-common.sh agents/lib/cheese-flair.sh chezmoi/lib/claude-mcp-reconcile.sh \
        chezmoi/lib/claude-plugin-reconcile.sh chezmoi/lib/install-agents-doc.sh \
        chezmoi/lib/install-shared-assets.sh agents/hooks/session-start-cheese-flair.sh \
        macos/.sync macos/lib.sh tests/run-tests.sh tests/install-bats.sh tests/lib/shard.sh \
        tests/workflows-test.sh tests/check-affected.sh | check -e SC1091 -s bash & lib=$!
    echo chezmoi/private_dot_codex/modify_private_config.toml | check -s sh & sh=$!
    rc=0
    for pid in "$bin" "$lib" "$sh"; do wait "$pid" || rc=1; done
    (( rc == 0 )) && echo "shellcheck: ok"
    exit "$rc"

PYTHON_LINT_PATHS := "skills/session-analytics/scripts/ skills/ci-optimize/scripts/ skills/bash-shortening/scripts/ skills/hill-climb/scripts/ skills/harness-climb/scripts/ tests/ci_optimize/ tests/hill_climb/ tests/harness_climb/ tests/lib/"

# ruff on python files
lint-python:
    ruff check {{PYTHON_LINT_PATHS}}
    ruff format --check {{PYTHON_LINT_PATHS}}

# eslint on JS hooks (config in claude/hooks/eslint.config.js)
lint-js:
    cd claude/hooks && eslint *.js

# markdownlint on markdown files (all, or the given files)
[positional-arguments]
lint-markdown *FILES:
    if [ "$#" -eq 0 ]; then set -- '**/*.md'; fi; markdownlint-cli2 "$@"

# autofix where supported (shellcheck has no autofix)
lint-fix: lint-python-fix lint-js-fix lint-markdown-fix

# ruff --fix + ruff format
lint-python-fix:
    ruff check --fix {{PYTHON_LINT_PATHS}}
    ruff format {{PYTHON_LINT_PATHS}}

# eslint --fix
lint-js-fix:
    cd claude/hooks && eslint --fix *.js

# markdownlint --fix
lint-markdown-fix:
    markdownlint-cli2 --fix '**/*.md'

# run all tests (bats + python)
test *ARGS:
    ./tests/run-tests.sh {{ARGS}}

# pytest on agent-profile, fanned across all cores via pytest-xdist. Kept out of
# pyproject addopts so a bare `pytest -k foo --pdb` stays serial and debuggable.
# Plain `uv run` (not --no-sync) so a cold or stale env self-heals rather than
# failing the gate.
test-python *ARGS:
    cd agent-profile && uv run pytest -n auto {{ARGS}}

# smoke tests — execute workflow definitions offline (all, or the given files)
[positional-arguments]
smoke *FILES:
    ./tests/workflows-test.sh "$@"

# validate the opt-in local-llm stack — shellcheck scripts + parse configs
check-llm:
    shellcheck -x -e SC1091 -s bash chezmoi/local-llm/scripts/executable_*.sh
    yq -e '.' chezmoi/local-llm/configs/litellm.yaml > /dev/null
    yq -e '.' chezmoi/local-llm/configs/llama-swap.yaml > /dev/null
    @echo "check-llm: ok"

# pre-push gate: run only the lint legs and test files that the change affects,
# compared with the merge base of origin/main. tests/lib/affected.py owns the
# selection; `just check --plan` prints it. CI still runs every leg.
# This gate stays read-only against source files; use `just lint-fix` explicitly
# when you want supported formatters to modify files.
[positional-arguments]
check *ARGS:
    ./tests/check-affected.sh "$@"

# full pre-push gate: every lint and test leg, fanned out by GNU parallel
check-all:
    ./tests/check-affected.sh --all
