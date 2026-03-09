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

# Run tests with coverage
test-coverage:
    uv run pytest --cov=src --cov-report=html --cov-report=term-missing

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

## Notes

- Always `uv run` instead of bare `python` or `pytest` — ensures correct venv
- Replace `myapp` with the actual module name from `pyproject.toml`
- If project uses `mypy`, add typecheck. If not (ruff-only), skip it
- For Django/FastAPI/Flask, add `dev` recipe with the framework's dev server
- For Alembic, add `migrate` / `rollback` recipes
- Check if `ruff` is configured — if not, `lint`/`fmt` might use `black`/`flake8` instead
