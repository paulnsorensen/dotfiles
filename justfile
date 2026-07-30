# dotfiles task runner

# list available recipes
default:
    @just --list

# run all linters
lint: lint-shell lint-python lint-js lint-markdown

# shellcheck on shell scripts
lint-shell:
    shellcheck -x -e SC1091 $(find bin -type f) .sync
    shellcheck -x -e SC1091 -s bash agents/mcp/sync.sh agents/hooks/sync.sh agents/hooks/lib.sh claude/plugins/sync.sh claude/lib/sync-common.sh agents/lib/cheese-flair.sh chezmoi/lib/claude-mcp-reconcile.sh chezmoi/lib/claude-plugin-reconcile.sh chezmoi/lib/install-agents-doc.sh chezmoi/lib/install-shared-assets.sh
    shellcheck -x -s sh chezmoi/private_dot_codex/modify_private_config.toml
    shellcheck -x -e SC1091 -s bash agents/hooks/session-start-cheese-flair.sh
    shellcheck -x -e SC1091 -s bash tests/run-tests.sh tests/install-bats.sh
    shellcheck -x -e SC1091 -s bash tests/workflows-test.sh
    @echo "shellcheck: ok"

# ruff on python files
lint-python:
    ruff check skills/session-analytics/scripts/

# eslint on JS hooks (config in claude/hooks/eslint.config.js)
lint-js:
    cd claude/hooks && eslint *.js

# markdownlint on markdown files
lint-markdown:
    markdownlint-cli2 '**/*.md'

# autofix where supported (shellcheck has no autofix)
lint-fix: lint-python-fix lint-js-fix lint-markdown-fix

# ruff --fix + ruff format
lint-python-fix:
    ruff check --fix skills/session-analytics/scripts/
    ruff format skills/session-analytics/scripts/

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

# smoke tests — execute workflow definitions offline
smoke:
    ./tests/workflows-test.sh

# validate the opt-in local-llm stack — shellcheck scripts + parse configs
check-llm:
    shellcheck -x -e SC1091 -s bash chezmoi/local-llm/scripts/executable_*.sh
    jq empty chezmoi/local-llm/configs/lean.json
    yq -e '.' chezmoi/local-llm/configs/litellm.yaml > /dev/null
    yq -e '.' chezmoi/local-llm/configs/llama-swap.yaml > /dev/null
    @echo "check-llm: ok"

# pre-push gate: autofix what we can, then lint + unit tests + smoke checks
check: lint-fix lint test test-python smoke
