# Python BDD implementation

Read this reference when binding pytest-bdd, isolating persistence, or checking a built artifact.
These commands apply to a new uv plus pytest-bdd project. Adapt them to existing project gates instead of replacing those gates.

## Bind and isolate

- Put scenarios in a feature file and bind them through a collected pytest module with `@scenario` or `scenarios(...)`.
- Check `pytest --collect-only` against the expected scenario count. A feature file alone is not a collected test.
- Register Gherkin tags as pytest markers when strict markers are enabled. Use `pytest -m` for selection.
- Use pytest fixtures for scenario-local state. Use `target_fixture` when a step supplies a fixture value.
- Run the public CLI in separate processes when process persistence matters. Pass argument lists, a timeout, and an isolated data location.
- Control the process environment without leaking secrets into logs.
- Inspect persisted state through a later public operation. Never seed or inspect the database directly when that bypasses the behavior under test.
- Assert exact stable fields: exit status, error category, entry identity, count, and amount. Prefer documented machine-readable output.
- For a rejected operation, compare before and after state. Assert that the prior data remains and rejected data is absent.
- Keep unit tests for parsing and arithmetic edge cases. Do not inflate BDD tables with every low-level permutation.

## New-project gate

Use the project's actual dependency groups and extras. Include `--all-extras` only when extras exist.

```sh
uv lock --check
uv sync --locked --dev
uv run --locked pytest --collect-only tests/bdd
uv run --locked pytest tests/bdd
# Run the existing full gate, such as just check.
project=$(pwd -P)
smoke="$project/tests/smoke_test.py"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
uv build --wheel --out-dir "$tmp/dist"
set -- "$tmp"/dist/*.whl
[ "$#" -eq 1 ] && [ -f "$1" ] || exit 1
wheel=$1
(cd "$tmp" && env -u PYTHONPATH -u PYTHONHOME uv run --isolated --no-project --with "$wheel" python -I "$smoke")
```

Run this block from the project root in a shell where `EXIT` traps are supported.
The fresh output directory selects one absolute wheel path without removing existing `dist/` artifacts.
The temporary working directory and isolated Python process exclude checkout imports.
The smoke script must exercise installed public behavior, not only import the package.
An editable environment can pass while the wheel omits a package file.
Keep the same required commands in CI. Follow repository policy for pinned actions and uv versions.
Cache dependency downloads only. Never cache secrets or treat a cache hit as a test result.

## Regression proof

Change one isolated production behavior temporarily only when safe, reversible, and within scope.
Run the focused scenario; record the failing assertion and exit code.
Restore production, then rerun the scenario and record its pass.
If production cannot be changed safely, report this proof as unrun rather than claiming it.
