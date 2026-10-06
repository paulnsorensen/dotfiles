---
name: hill-climb
model: opus
effort: high
description: Drive one metric down (or up) through repeated measured iterations, then lock each gain with a ratchet gate. Use for "make X faster", "hill climb this", "drive this number down", "add a ratchet", "/hill-climb", or one iteration of a /loop or codex exec loop. Each run does one iteration and records state on disk, so it is safe to repeat. Route one-off local timing to /build-optimize and GitHub Actions wait time to /ci-optimize.
---

# Hill climb

This skill applies the method from "How we made claude.ai 3x faster" (Anthropic, 2026-09-23).
Measure a deterministic count, improve it, and ratchet the gain so that CI keeps it.
One invocation is one iteration. A loop runs the skill until a stop condition occurs.

## Discipline

**Iron Law:** Do not optimize without a deterministic benchmark that shows the problem.

**Red Flags** — stop when you notice these:

1. The metric is wall-clock time and a deterministic count is available.
2. A change makes the benchmark better but removes a check, a test, or behavior.
3. You loosen a ratchet threshold, or you skip the gate to merge.
4. A user-visible change ships without a flag or without before-and-after evidence.

| Rationalization | Why it fails | Required action |
| --- | --- | --- |
| "Wall-clock is what users feel." | Noise hides small gains and fakes regressions. | Ratchet a count. Use wall-clock only to confirm correlation. |
| "The target is met, so the thread is done." | Targets are not the stopping point. | Continue until diminishing returns or a human stop. |
| "The benchmark is green, so the fix works." | A benchmark can measure the wrong thing. | Prove red on base and green on the change before you adopt it. |

## References

Read [metrics.md](references/metrics.md) before you choose or build a benchmark.
Read [ratchet.md](references/ratchet.md) before you add a metric or wire the gate.

## Thread state

One thread holds one journey and one primary metric. Keep threads narrow.
State lives in `.hill-climb/<thread>/` in the consumer repository:

- `thread.md` — goal, journey, metric name, benchmark command, ratchet file path, and human owner.
- `ledger.md` — one line per iteration: number, change, before, after, verdict, and commit.
- `STOP` — its presence ends the loop. Its first line is the reason.

Commit the ratchet file. Do not commit `.hill-climb/` unless the repository already tracks it.

## Iteration

1. If `STOP` exists, report its reason and end. Under Claude `/loop`, stop the loop.
2. Read `thread.md` and the last five ledger lines. On the first run, write `thread.md` from the request.
3. Find or build the benchmark. It must print one number on its last stdout line.
4. Run `ratchet.py measure --runs 5 -- <benchmark>`. Require `deterministic: true`.
5. On first adoption, prove correlation with user latency, and prove red on base and green on a fix.
6. If the ratchet file lacks the metric, run `ratchet.py add` with the measured value.
7. If CI does not run `ratchet.py check`, wire it as described in ratchet.md.
8. Trace the hot path. List candidate changes with an estimate in metric units.
9. Select the candidate with the largest estimate per unit of risk. Skip ledger false leads.
10. Confirm that tests cover the affected behavior. Add tests first if they do not.
11. Make the smallest change. Put user-visible changes behind a short-lived flag.
12. Measure again with the same protocol. Run the repository gates.
13. If the metric did not improve or a gate fails, revert the change and log a false lead.
14. If it improved, run `ratchet.py tighten`. Commit the change and the ratchet file together.
15. Append the ledger line. Name the next candidate in the same journey.
16. Write `STOP` when a stop condition occurs.

Size each commit or pull request for review. Several small changes are better than one large change.
When deploy telemetry exists, read field data after release. If the field metric did not improve, turn off the flag and log it.

## Stop conditions

- Three consecutive iterations without a gain: write `STOP` with `diminishing-returns`.
- A trade-off needs human taste: write `STOP` with `needs-human` and the before-and-after evidence.
- The benchmark becomes nondeterministic or a gate breaks for an unrelated cause: write `STOP` with `blocked`.
- The human owner asks to stop.

A met target is not a stop condition. Report it and continue.

## Steering

- **Ambition:** Propose the change now. Do not defer a safe change to a later week.
- **Taste:** The named owner decides user-perceptible trade-offs. Show before-and-after evidence.
- **Direction:** Keep one thread on one benchmark. Start a new thread for a new journey.

## Guardrails

- Every change gets automated review and at least one human approval.
- Tests come before the optimization.
- Flags are kill switches or ramps. Remove each flag when the change is safe.
- Never loosen a threshold through the helper. Loosening is a human edit with a reason in the pull request.

## Loop drivers

Claude Code, self-paced: `/loop /hill-climb <thread>`.
Claude Code, fixed interval: `/loop 30m /hill-climb <thread>`.
Claude Code, parallel threads: run the `hill-climb-threads` workflow.

Codex has no loop command. Drive it from the shell:

```bash
thread=sidebar-commits
until [[ -e .hill-climb/$thread/STOP ]]; do
  codex exec -s workspace-write "Use the hill-climb skill. Run one iteration of thread $thread." || break
done
cat ".hill-climb/$thread/STOP"
```

## Commands

Resolve `RATCHET` from the directory of the loaded `SKILL.md`: `<skill-dir>/scripts/ratchet.py`.
Resolve symlinks first. Do not derive the path from the consumer repository.

```text
python3 "$RATCHET" measure --runs 5 [--tolerance T] -- COMMAND ARGS
python3 "$RATCHET" add --file FILE --metric NAME --direction lower|higher --value V [--unit U] [--command CMD]
python3 "$RATCHET" check --file FILE --value NAME=V [--value NAME=V ...] [--partial]
python3 "$RATCHET" tighten --file FILE --value NAME=V [--revision REV]
```

Exit 0 is pass. Exit 1 is a gate failure. Exit 2 is an input error.

## Report

Return no more than 150 words: thread, iteration, change, before and after values, ratchet status, gates, next candidate, and loop status.
