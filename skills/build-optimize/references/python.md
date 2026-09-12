# Python local build, test, and check options

## pytest-xdist

Use `-n auto` only after tests support parallel resources. Workers are separate processes, but they can share files, databases, ports, and other external resources. Give each worker a unique resource. [xdist how-to](https://pytest-xdist.readthedocs.io/en/stable/how-to.html)

Keep collection consistent across workers. Use worker-aware fixtures for resources and session setup. Verify this boundary before using `-n auto`. [xdist distribution](https://pytest-xdist.readthedocs.io/en/stable/distribution.html)

## uv cache

Use separate commands for separate cache actions:

- `uv cache clean` removes cache data.
- `uv sync --refresh` refreshes package metadata.
- `uv sync --reinstall` reinstalls packages.

Do not treat these actions as synonyms. Choose the action that matches the failure. [uv cache](https://docs.astral.sh/uv/concepts/cache/)

## Ruff

Preserve explicit rule coverage when Ruff replaces another linter or formatter. Confirm equivalent rules before removing a tool. Run `ruff format --check` in verification gates. Do not replace that check with an autoformat command. [Ruff linter](https://docs.astral.sh/ruff/linter/) [Ruff formatter](https://docs.astral.sh/ruff/formatter/)

## pytest cache flags

Use `--lf` to run only the last failed tests. Use `--ff` to run the full suite with previous failures first. These flags support local iteration; they do not replace the required full test gate. [pytest cache](https://docs.pytest.org/en/stable/how-to/cache.html)
