# dotfiles task runner

# list available recipes
default:
    @just --list

# run all linters
lint: lint-shell lint-python lint-js lint-markdown

# shellcheck on shell scripts
lint-shell:
    shellcheck -x -e SC1091 $(find bin -type f) .sync
    shellcheck -x -e SC1091 -s bash agents/mcp/sync.sh agents/hooks/sync.sh agents/hooks/lib.sh claude/plugins/sync.sh claude/lib/sync-common.sh agents/lib/cheese-flair.sh chezmoi/lib/claude-mcp-reconcile.sh chezmoi/lib/claude-plugin-reconcile.sh chezmoi/lib/install-agents-doc.sh chezmoi/lib/install-codex.sh chezmoi/lib/install-shared-assets.sh
    shellcheck -x -e SC1091 -s bash agents/hooks/session-start-cheese-flair.sh
    shellcheck -x -e SC1091 -s bash tests/run-tests.sh tests/install-bats.sh
    shellcheck -x -e SC1091 -s bash tests/workflows-test.sh
    @echo "shellcheck: ok"

# ruff on python files
lint-python:
    ruff check skills/session-analytics/scripts/ agent-profile/agent_profile/

# eslint on JS hooks (config in claude/hooks/eslint.config.js)
lint-js:
    cd claude/hooks && eslint *.js

# markdownlint on markdown files
lint-markdown:
    markdownlint-cli2 '**/*.md'

# autofix where supported (shellcheck has no autofix)
lint-fix: lint-python-fix lint-js-fix lint-markdown-fix

# ruff --fix + ruff format. agent-profile is check-only: `ruff format` over the
# package is a ~300-line reformat unrelated to any lint rule, so it stays out
# until someone lands it as its own commit.
lint-python-fix:
    ruff check --fix skills/session-analytics/scripts/ agent-profile/agent_profile/
    ruff format skills/session-analytics/scripts/

# eslint --fix
lint-js-fix:
    cd claude/hooks && eslint --fix *.js

# markdownlint --fix
lint-markdown-fix:
    markdownlint-cli2 --fix '**/*.md'

# run python + bats tests
test *ARGS: test-python (test-bats ARGS)

# agent-profile pytest suite
test-python:
    uv run --project agent-profile --frozen -m pytest agent-profile/tests

# bats test suite
test-bats *ARGS:
    ./tests/run-tests.sh {{ARGS}}

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
check: lint-fix lint test smoke
