# dotfiles task runner

# list available recipes
default:
    @just --list

# run all linters
lint: lint-shell lint-python lint-js lint-markdown

# shellcheck on shell scripts
lint-shell:
    shellcheck -x -e SC1091 bin/* .sync .sync-with-rollback
    shellcheck -x -e SC1091 -s bash claude/hooks/*.sh claude/mcp/sync.sh claude/plugins/sync.sh claude/lib/sync-common.sh
    shellcheck -x -e SC1091 -s bash tests/run-tests.sh tests/install-bats.sh
    @echo "shellcheck: ok"

# ruff on python files
lint-python:
    ruff check claude/skills/merge-resolve/scripts/ claude/skills/session-analytics/scripts/

# eslint on JS hooks (eslint v8 for --no-eslintrc support)
lint-js:
    cd claude/hooks && eslint --no-eslintrc --env node --env es2020 \
        --rule '{"no-undef": "error", "no-unused-vars": "warn", "no-redeclare": "error"}' \
        *.js

# markdownlint on markdown files
lint-markdown:
    markdownlint-cli2 '**/*.md'

# run all tests
test *ARGS:
    ./tests/run-tests.sh {{ARGS}}
