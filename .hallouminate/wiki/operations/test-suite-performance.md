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

GitHub CI's `test` job runs `just test` (Bats), `just test-python` (agent-profile pytest), and `just smoke` (Node workflow tests) as separate steps. The workflow-smoke test asserts those exact recipes so deleting one fails before merge.[^10]

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

## First-exec assessment tax (2026-07-31)

macOS syspolicyd assesses every **new executable inode** on its first exec (~150–300 ms under load). A test file that writes or copies mock executables per test pays that tax per mock per test. `cp -p` from a `setup_file` master creates new inodes, so the 2026-07-25 packages fix (build once, copy per test) did not remove the cost. Evidence: xtrace timestamps on one solo `packages.bats` test showed each mock's *first* invocation slow (`brew tap` 175 ms, `mise install` 229 ms, one-shot `curl|sh` 318 ms) with repeats fast; the file summed 661 s of the suite's 1,826 s duration-sum (70 tests, 9.4 s avg under 15-job load, 2.06 s solo).[^12]

Fix pattern (implemented in `tests/packages.bats`): **symlink** the `setup_file`-built mocks into each test's `MOCK_BIN` instead of copying — exec through a symlink assesses the shared target inode once per suite run. Invariants the pattern depends on:

- Every mock writer must `rm -f` its target before `cat >`: writing through a symlink truncates the shared master and corrupts concurrently running tests. This includes inline `cat > "$MOCK_BIN/…"` sites in test bodies, not just the `write_mock_*` helpers.
- Shared mocks must resolve log paths from the environment at runtime (escaped `\$VAR` in heredocs), never baked in at write time — `write_mock_sh`/`write_mock_mise` previously baked `$TEST_HOME` paths via unquoted heredoc delimiters.
- Tests that simulate a missing tool via `rm -f "$MOCK_BIN/x"` still work (removes the symlink); the shared master dir must therefore never be added to `PATH`.

Result: the whole file runs in 7–10 s at 15 jobs; the full Bats leg fell from 247 s to ~155 s. The same pattern applied to `tests/sync-orchestrator.bats` (renamed from `sync-rollback.bats` — the rollback subsystem it was named for was deleted in the chezmoi consolidation; the file tests the live `.sync` orchestrator) took it from 104 s duration-sum (13 tests, ~8 s avg under load) to 3.3–3.6 s for the whole file. Remaining files with the same per-test executable-writing shape (duration-sums from the 2026-07-31 profile, contention-inflated): turn-budget-guard 117 s, tool-reroute 93 s, git-guard 69 s, local-llm 66 s, sensitive-file-guard 65 s. chezmoi-wiring's end-to-end apply test ran 57.6 s under load and bounds the parallel tail.

External research (2026-07-31, cited long-form under the durable corpus's `research/bats-parallel-overhead/` and `research/macos-first-exec-assessment/`): bats-core evaluates each `.bats` file n+1 times — one counting pass plus a fresh child process per `@test` that re-sources the whole file — so heavy top-level file code multiplies by test count; GNU parallel's dispatch floor is 3–10 ms/job (negligible here); no faster dispatcher exists in bats-core (rush/jobserver requests unimplemented). On the macOS side, the one Apple-supported system-level lever is the Developer Tools exemption (`spctl developer-mode enable-terminal`), which verifiably removes first-exec scanning for processes launched by that terminal; however sources only demonstrate the assessment tax for Mach-O binaries — whether bare `#!/bin/bash` scripts are assessed at all is unconfirmed (our symlink fix works either way; attribute before broadening any exemption via `log stream --predicate 'process == "syspolicyd" || process == "XprotectService"'`).

## Gate layout and env leak (2026-07-31)

`check` now runs `lint-fix` serially first (it mutates files, and the fixable linters gate through it — `ruff check --fix`, `eslint --fix`, and `markdownlint-cli2 --fix` all exit non-zero on unfixable findings), then fans out `lint-shell`, `test-python`, `smoke`, and `test` via GNU parallel. Plain `lint` stays out of the gate as redundant with `lint-fix` + `lint-shell`. `just check` fell from 291 s serial to 157 s wall.[^13]

`packages.bats` `setup()` now unsets `DOTFILES_DEV`: leaked as `true` from the invoking shell, `heal_missing_cask_apps` (#569) runs `brew list --cask` on the cache-hit path on Darwin, failing the two cache-skip tests on dev machines while Linux CI stays green (the heal is Darwin-only). Tests opt in explicitly.

## Benchmarking protocol

Use at least three warm runs and report the median. Bats supports `-T/--timing`; use JUnit output to aggregate testcase duration by `classname`, but validate suspected files alone because parallel resource contention inflates individual test durations. Compare the existing CPU-count job setting with one lower and one oversubscribed value before changing it.

[^1]: Local benchmark, 2026-07-25: `/usr/bin/time -p bats --jobs {8,15,30} tests/*.bats`; 15-job runs were 239.28s, 256.02s, and 264.59s.
[^12]: Local benchmark, 2026-07-31: `bats --formatter tap13 --timing --jobs 15 tests/*.bats` aggregated per file; solo trace via `BASH_ENV` xtrace shim with `PS4='+$EPOCHREALTIME'` gated on `$0 == */sync.sh`.
[^13]: Local benchmark, 2026-07-31: `time just check` — 291.1 s serial-leg sum before (bats 247.5, pytest 34.9, lint 5.5, lint-fix 1.3, smoke 1.9), 157.2 s wall after, exit 0. justfile:71-80; tests/packages.bats:12-68.
[^2]: tests/chezmoi-wiring.bats:56-300
[^3]: chezmoi/.sync:39-49; .sync-lib.sh:489-613
[^4]: tests/chezmoi-wiring.bats:68-77,717-798
[^5]: fbc80c6:tests/agents-hooks-sync.bats:17-21; fbc80c6:agents/hooks/lib.sh:410-448
[^6]: tests/agents-hooks-sync.bats:17-49
[^7]: fbc80c6:tests/packages.bats:12-45,47-187,208-210
[^8]: tests/test_helper.bash:44-58
[^9]: agent-profile/tests/test_canonical_permissions.py:93-118; local `uv run pytest -q --durations=20`, 2026-07-25.
[^10]: justfile:51-68; tests/workflows-test.sh:1-18
