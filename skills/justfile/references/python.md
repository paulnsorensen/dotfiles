# Python Justfile Recipes

Always use `uv` as the package manager (user preference).

## Template

```just
set dotenv-load := true

default: check

# Run all checks
check: lint typecheck test

# Install dependencies
install:
    uv sync

# Install with dev + all extras
install-dev:
    uv sync --all-extras --dev

# Run the app
run *args:
    uv run python -m myapp {{args}}

# Run tests
test *args:
    uv run pytest {{args}}

# Run tests with coverage (threshold enforced via pyproject.toml)
test-coverage:
    uv run pytest --cov=src --cov-report=html --cov-report=json --cov-report=term-missing

# Per-file coverage gate (workaround — no native pytest-cov support as of 2026)
cov-per-file MIN="70":
    uv run pytest --cov=src --cov-report=json -q
    jq -r --argjson min {{MIN}} \
        '.files | to_entries[] | select(.value.summary.percent_covered < $min) | "\(.key): \(.value.summary.percent_covered | round)%"' \
        coverage.json | (! grep . || { echo "Files below {{MIN}}%"; exit 1; })

# Ratchet: never let overall coverage regress (reads/writes .coverage-baseline)
cov-ratchet:
    #!/usr/bin/env bash
    CUR=$(jq '.totals.percent_covered' coverage.json)
    BASE=$(cat .coverage-baseline 2>/dev/null || echo 0)
    awk -v c=$CUR -v b=$BASE 'BEGIN{exit !(c>=b)}' \
        && echo $CUR > .coverage-baseline \
        || { echo "Coverage regression: $CUR% < $BASE%"; exit 1; }

# Lint (check only)
lint:
    uv run ruff check .
    uv run ruff format --check .

# Format and auto-fix
fmt:
    uv run ruff format .
    uv run ruff check --fix .

# Type checking
typecheck:
    uv run mypy src/

# Build distribution
build:
    uv build

# Publish to PyPI
publish: check build
    uv publish

# Clean artifacts
clean:
    find . -type d -name __pycache__ | xargs rm -rf
    find . -name "*.pyc" -delete
    rm -rf .coverage htmlcov/ dist/ build/ *.egg-info
```

## Coverage config (pyproject.toml)

```toml
[tool.coverage.report]
fail_under = 85
show_missing = true
skip_covered = false
exclude_also = ["if TYPE_CHECKING:", "raise NotImplementedError"]

[tool.pytest.ini_options]
addopts = "--cov=src --cov-report=term-missing --cov-report=json --cov-fail-under=85"
```

The `fail_under` in `[tool.coverage.report]` is the single source of truth — it's what `--cov-fail-under` reads. Per-file thresholds are not natively supported (pytest-cov issue #444); use the `cov-per-file` recipe above as a workaround. Commit `.coverage-baseline` to enforce ratcheting in CI.

## Notes

- Always `uv run` instead of bare `python` or `pytest` — ensures correct venv
- Replace `myapp` with the actual module name from `pyproject.toml`
- If project uses `mypy`, add typecheck. If not (ruff-only), skip it
- For Django/FastAPI/Flask, add `dev` recipe with the framework's dev server
- For Alembic, add `migrate` / `rollback` recipes
- Check if `ruff` is configured — if not, `lint`/`fmt` might use `black`/`flake8` instead
