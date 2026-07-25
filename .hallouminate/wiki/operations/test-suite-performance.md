# Test Suite Performance

The Bats suite is dominated by repeated integration setup, not by insufficient runner parallelism. On a 15-core macOS host, 1,246 tests took 239–265 seconds with 15 jobs; 8 jobs regressed to 334 seconds and 30 jobs took 266 seconds. Keep the CPU-count default and shorten the work inside tests before tuning job count.[^1]

## Highest-payoff targets

### Stop full Claude/OMP assembly in narrow chezmoi tests

`tests/chezmoi-wiring.bats` took 159 seconds alone. Nine early tests invoke the complete `chezmoi/.sync` orchestration while asserting only config preservation, source selection, or two legacy-symlink cases.[^2] Every successful invocation rebuilds the registry-selected Claude and OMP exact trees before the mocked `chezmoi apply`; the source functions stage, copy, delete, and replace those trees.[^3]

The implementation extracts config/bootstrap/migration logic into sourced functions and tests those seams directly. One end-to-end `.sync` test retains ordering and apply coverage, using a per-test source destination so the file can parallelize safely.[^4]

### Remove the hook-sync serialization defect

`tests/agents-hooks-sync.bats` previously took 44 seconds and serialized 79 tests because `hook_codex_apply` used `mktemp ".../hook-sync.XXXXXX.toml"`; BSD `mktemp` does not randomize that template when `XXXXXX` is not the suffix.[^5] The implementation uses trailing `XXXXXX`, removes file serialization, and caches registry JSON at file scope instead of running `yq` plus harness filtering in every setup.[^6]

### Reduce repeated package-script setup

`tests/packages.bats` previously took 35 seconds alone. Its 52 tests each wrote seven executable mocks, and 32 executed the entire package sync script.[^7] Immutable mock executables now initialize in `setup_file` and copy into each isolated sandbox; representative normal, upgrade, and failure paths retain full integration coverage.

## Second wave

- `teardown_test_env` now tries `rm -rf` first, then uses `chmod -R` and retries only after failure. A few Go/prek caches can still require the fallback.[^8]
- Workflow parsing is cached by path in `tests/workflows/harness.mjs`; each execution still receives a fresh VM context.
- Reusing prepared Git repository histories through local clones/worktrees in `ccw-sweep`, `git-file-risk`, and similar suites remains a measured follow-up.
- Pytest's read-only `global_manifest` and `opencode_global_manifest` fixtures are module-scoped. Previously, eight repeated setups each cost roughly one second in the 2026-07-25 profile.[^9]

## Gate mismatch

`just test` and `just check` run Bats, while `just smoke` runs Node workflow tests; neither invokes the 909-test `agent-profile` pytest suite.[^10] A local pytest run took 25–38 seconds and exposed four failures on 2026-07-25. Treat adding pytest to the gate as a coverage correction, benchmarked separately from Bats speed work.[^11]

## Implemented results (2026-07-25)

The speed changes reduced a warm full Bats run from the 256.02-second pre-change median to 169.03 seconds, saving 86.99 seconds (34.0%). A final `just check` completed in 155.25 seconds with all 1,251 Bats tests and 152 workflow smoke tests passing.[^result-gate]

- Chezmoi wiring fell from 231.54 to 26.51 seconds after config/migration seams moved into `.sync-lib.sh`; the retained production `.sync` end-to-end run covers all seven exact-tree categories, external vendoring, agent frontmatter, and executable hook attributes.[^result-chezmoi]
- Hook sync fell from 46.76 seconds to an uncontended 18.31 seconds by fixing BSD `mktemp` templates and removing file serialization.[^result-hooks]
- Package tests fell from 39.03 to 27.97 seconds by constructing immutable mock executables once per file and copying them into each sandbox.[^result-packages]
- Workflow smoke fell from 0.50 to 0.37 seconds by caching compilation while retaining a fresh VM context per run.[^result-workflows]
- Canonical-permission pytest fell from 9.71 to 4.90 seconds by making shipped-manifest fixtures module-scoped.[^result-pytest]

The full agent-profile pytest result remains the same known baseline: 903 passed, 2 skipped, and four Serena-contract failures; the speed diff did not change those failing tests.[^result-pytest-baseline]

[^result-gate]: Local benchmark, 2026-07-25: `/usr/bin/time -p just test`; `/usr/bin/time -p just check`.
[^result-chezmoi]: .sync-lib.sh:31-149; chezmoi/.sync:32-50; tests/chezmoi-wiring.bats:717-798
[^result-hooks]: agents/hooks/lib.sh:278-306,349-364,410-448; tests/agents-hooks-sync.bats:17-49
[^result-packages]: tests/packages.bats:12-44
[^result-workflows]: tests/workflows/harness.mjs:6,149-169; tests/workflows/harness.test.mjs:50-69
[^result-pytest]: agent-profile/tests/test_canonical_permissions.py:96-118
[^result-pytest-baseline]: Local benchmark, 2026-07-25: `uv run pytest -q`; identical failures before and after the speed changes.

## Benchmarking protocol

Use at least three warm runs and report the median. Bats supports `-T/--timing`; use JUnit output to aggregate testcase duration by `classname`, but validate suspected files alone because parallel resource contention inflates individual test durations. Compare the existing CPU-count job setting with one lower and one oversubscribed value before changing it.

[^1]: Local benchmark, 2026-07-25: `/usr/bin/time -p bats --jobs {8,15,30} tests/*.bats`; 15-job runs were 239.28s, 256.02s, and 264.59s.
[^2]: tests/chezmoi-wiring.bats:56-300
[^3]: chezmoi/.sync:39-49; .sync-lib.sh:489-613
[^4]: tests/chezmoi-wiring.bats:68-77,717-798
[^5]: fbc80c6:tests/agents-hooks-sync.bats:17-21; fbc80c6:agents/hooks/lib.sh:410-448
[^6]: tests/agents-hooks-sync.bats:17-49
[^7]: fbc80c6:tests/packages.bats:12-45,47-187,208-210
[^8]: tests/test_helper.bash:44-58
[^9]: agent-profile/tests/test_canonical_permissions.py:93-118; local `uv run pytest -q --durations=20`, 2026-07-25.
[^10]: justfile:51-68; tests/workflows-test.sh:1-18
[^11]: Local benchmark, 2026-07-25: `uv run pytest -q --durations=20`; 903 passed, 2 skipped, 4 failed in 25.11s.
