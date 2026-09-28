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

## Gate strategy

Use this order for a slow Python gate. Measure after each step with the approved protocol.

1. Time each gate step once. Find the steps that dominate the total.
2. Run independent read-only steps as concurrent lanes. Keep a producer and its consumers in one lane, such as `coverage.xml` and `diff-cover`.
3. Report every failing lane in declared order. One lane failure must not hide another lane.
4. Measure several xdist worker counts. Stop at the point where more workers give no gain.
5. Use `--dist worksteal` when test durations are uneven. [xdist distribution](https://pytest-xdist.readthedocs.io/en/stable/distribution.html)
6. Give browser and Playwright suites their own small `-n` value. Their fixtures often bind port 0 and are already isolated.
7. Give each concurrent pytest process its own `-o cache_dir=...`. Concurrent runs otherwise write one `.pytest_cache`.

Before you measure the new protocol, run the parallel gate several times in a loop. Parallel runs expose races that serial runs hide:

- A test mutates a shared source file in place. Another worker reads the mutated file. Mutate a private copy under `tmp_path`.
- A test fake signals completion before its thread exits. Join the recorded thread before the test acts on completion.

Fix each race in the test. Do not serialize the suite to hide a race.

## Affected-only selection with pytest-testmon

Use pytest-testmon only for inner-loop runs. Keep the full, unselected suite in every exit gate and pull request gate.

- testmon supports xdist from version 1.4. [testmon xdist](https://www.testmon.org/blog/v14-with-xdist-support-is-out)
- testmon misses static and data files, subprocess dependencies, dynamic imports, and external services. [testmon](https://www.testmon.org)
- A coverage gate needs the full suite. Do not combine affected-only selection with `--cov-fail-under` or diff coverage.
- testmon disables selection when `-m` is present. Exclude suites with `--ignore=<path>`. Check the `testmon:` header line to confirm selection.
- testmon stores `.testmondata` as SQLite in the worktree. Add `.testmondata*` to `.gitignore`.
- Keep one `.testmondata` for each worktree. No source confirms that concurrent writers can safely share one file.

## Pants and Bazel

Do not recommend Pants or Bazel for a single-package uv repository without measured evidence of a remaining gap.

- Pants has no native uv resolver. It builds lockfiles through Pex. [Pants lockfiles](https://www.pantsbuild.org/dev/docs/python/overview/lockfiles)
- Pants ships experimental pyright. basedpyright needs the third-party `pants-basedpyright` plugin. [pants-basedpyright](https://pypi.org/project/pants-basedpyright)
- Pants caches each test file as a separate process. A `fail_under` threshold applies only after coverage combines. [Pants test goal](https://www.pantsbuild.org/dev/docs/python/goals/test)
- import-linter, vulture, custom scripts, and npm tools need hand-written `adhoc_tool` or `shell_command` targets.

Concurrent lanes and xdist tuning usually remove most gate time at a small fraction of this cost.

## Agent fleets and concurrent worktrees

Many agents can run a gate at the same time on one host. Plan for that load.

- `-n auto` starts one worker per core in each worktree. Expose the worker count as an overridable variable, such as `just TEST_WORKERS=6 check`.
- Share the uv cache across worktrees through `UV_CACHE_DIR`. The uv cache is safe for concurrent use. Do not share the virtual environment. [uv cache](https://docs.astral.sh/uv/concepts/cache/)
- Report a fleet recommendation as untested unless you measured concurrent gates.
