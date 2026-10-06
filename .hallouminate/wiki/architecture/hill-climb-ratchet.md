# Hill climb and the ratchet gate

The `hill-climb` skill and the `hill-climb-threads` Claude workflow apply the method from [[sources/how-we-made-claude-ai-faster]].
The skill runs one measured iteration per invocation. The workflow runs several narrow threads in parallel.

## Ratchet gate

A **ratchet gate** is a CI check with one threshold per deterministic metric. The threshold moves only toward the better value. A regression fails the build.
The article names it "a guardrail in CI with ratcheting thresholds". It is how a gain survives after the thread ends.

`skills/hill-climb/scripts/ratchet.py` implements it with the standard library only:

- `add` records a metric, its direction (`lower` or `higher`), and its first threshold.
- `check` is the gate. It fails on a regression and on a missing metric, so a deleted benchmark cannot pass silently. `--partial` permits a subset for loop iterations.
- `tighten` moves thresholds to better values. A worse value makes it refuse and write nothing, even for the other metrics in the same call.
- `measure` runs the benchmark N times and fails when the spread exceeds the tolerance.

Exit codes match `ci_optimize.py`: 0 pass, 1 gate failure, 2 input error.

## Decisions

**Counts, not durations.** The ratchet holds deterministic counts (instructions, commits, queries, syscalls). Wall-clock time only confirms correlation. A noisy metric makes a ratchet gate flaky, and a flaky gate gets skipped.

**No loosen command.** The helper cannot relax a threshold. A human edits the JSON and states the trade-off in the pull request. This keeps every regression visible in review.

**Adoption proof.** A new benchmark needs correlation with user latency and a repro: red on base and green on the fix, repeated (the article used 20 of 20). Without the repro, a green benchmark can measure the wrong thing.

**One iteration per invocation.** The skill keeps state in `.hill-climb/<thread>/` (`thread.md`, `ledger.md`, `STOP`). Any loop driver can repeat it. Claude uses `/loop /hill-climb <thread>`. Codex has no loop command, so a shell `until [[ -e .hill-climb/$thread/STOP ]]` loop calls `codex exec`. The `STOP` file is the only shared termination signal both harnesses can see.

**A met target does not stop the loop.** The article's steering said targets are not the stopping point. Stop conditions are three dry iterations, a human-taste decision, a blocked gate, or an owner request.

**One ratchet file per workflow thread.** `hill-climb-threads` gives each thread `<ratchetDir>/<slug>.json` (default `perf/ratchet/`). Parallel branches that each tighten one shared JSON file would conflict on merge.

**Skeptic verify per gain.** Each claimed gain gets an independent agent that re-measures, runs `check`, and reads the diff for removed checks. A refuted or crashed verify counts as no gain. The next round must revert the commit, and the thread cannot publish while a refutation is pending.

**No barrier between threads.** Each thread loops on its own inside one `parallel()` call. A fast thread never waits for a slow one. Round 1 creates the worktree; later rounds `cd` into its path (see the worktree gotcha in [[saved-workflows]]).

**Publish is opt-in.** `publish: true` opens one draft PR per thread with a verified gain, through `/plate`. The default returns branches only, because the article required human approval on every PR.

## Deployment

The skill lives in `skills/hill-climb/`. Claude selects it through `claude.skills` in `chezmoi/.chezmoidata/claude.yaml`. Codex, Cursor, and Pi receive the local skill tree through `~/.agents/skills`.
The workflow lives in `claude/workflows/hill-climb-threads.js` and is Claude-only. Tests: `tests/hill-climb.bats` (wraps `tests/hill_climb/`) and `tests/workflows/hill-climb-threads.test.mjs`.
