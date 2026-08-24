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
    shellcheck -x -e SC1091 -s bash agents/hooks/session-start-cheese-flair.sh macos/.sync macos/lib.sh
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
    yq -e '.' chezmoi/local-llm/configs/litellm.yaml > /dev/null
    yq -e '.' chezmoi/local-llm/configs/llama-swap.yaml > /dev/null
    @echo "check-llm: ok"

# pre-push gate: lint-fix mutates files first (must not race readers) and
# already gates the fixable linters (ruff/eslint/markdownlint --fix all exit
# non-zero on unfixable findings); shellcheck has no fixer so it still runs
# standalone. The remaining legs are independent and IO/CPU-bound, so they
# fan out via GNU parallel; bats (test) goes last since it's the slowest.
# Plain `lint` stays out of the gate — its fixable legs are redundant with
# lint-fix, and lint-shell already covers the one leg that needs no fixer.
check: lint-fix
    @mkdir -p "$HOME/.parallel" && touch "$HOME/.parallel/will-cite"
    # GNU parallel exports XDG_CACHE_HOME to its jobs even when it is unset in
    # the parent, and an empty value makes mise resolve its cache dir to a
    # *relative* `mise`, dumping aqua bin_paths caches into the repo root. Pin
    # a real value so the shimmed tools every leg runs cache under $HOME.
    XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}" parallel -k --group just ::: lint-shell test-python smoke test
