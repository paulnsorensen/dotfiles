# Hill climb vs RRSI

This page compares the [[hill-climb-ratchet]] skill with RRSI, the harness-search loop in `google-research/rrsi`. Both are greedy climbs from one incumbent. Hill climb requires a deterministic metric. RRSI accepts a noisy one. That difference decides which loop can judge an edit to an agent harness.

## Conclusion

- Hill climb cannot judge a harness edit alone. An agent's task outcomes are not deterministic, and the hill-climb Iron Law rejects a noisy metric.
- The hill-climb **ratchet** fits the deterministic guards of a harness loop, for example the instruction-token counts in `agents/instruction-budgets.toml`. Those budgets do not tighten automatically today.
- The hill-climb **driver shape** fits a PR-gated harness loop: one iteration per invocation, state on disk, a `STOP` file, and human approval on each PR.
- RRSI supplies the parts that hill climb lacks for noisy metrics: k trials per task, a noise band, a token-cost rule, and a leakage critic.

## Shared skeleton

Each step makes a change, measures it, and keeps or reverts it. Each loop keeps one incumbent. Each loop stops on a `STOP` file (`.hill-climb/<thread>/STOP` in hill climb, `runs/<domain>/STOP` in RRSI). Each loop keeps a ledger (`ledger.md` in hill climb, `history.jsonl` in RRSI).

## Differences

| Aspect | Hill climb | RRSI |
| --- | --- | --- |
| Metric | A deterministic count. `ratchet.py measure --runs 5` must report `deterministic: true`. | A stochastic task score. k trials per task and a noise band δ absorb run-to-run variance. |
| Candidates per step | One. The agent traces the hot path and picks the best estimate per unit of risk. Parallel threads chase different metrics. | m variants that compete on the same metric. An analyst pass reads the worst and best traces first. Separate proposers write the variants. |
| Objective | One primary metric per thread. | Score, plus a token-cost rule, plus domain guards. A gain inside δ must save tokens or add a new structural component. |
| Anti-cheat | Red flags for a removed check or test. A skeptic agent re-measures and reads the diff after each claimed gain. | A regex denylist and an LLM critic reject benchmark-specific edits before evaluation. Edits are re-tagged from the real diff. |
| Locking the gain | A CI ratchet. The threshold only tightens. Loosening is a human edit with a reason in the PR. | `S*` in `frontier.json` only. Nothing in CI stops a later hand edit from a regression. |
| Human role | Human approval on every PR. Publishing is opt-in. | The loop accepts the winner to the `evolve/<domain>` branch with no human step. |
| Driver | One iteration per invocation. Claude `/loop` or a shell `until` loop repeats it. | `driver.py` runs rounds until T. |

## Why the metric rule decides fit

Hill climb uses determinism as its defense against noise. A noisy metric makes a ratchet gate flaky, and a flaky gate gets skipped. RRSI uses statistics as its defense. It repeats each task and accepts a candidate only outside the noise band. A harness edit changes model behavior, so its outcome metric is noisy. Only the RRSI defense applies to that metric. The deterministic side metrics of the same edit, such as instruction tokens per source file, still suit a ratchet.

## Decision context

On 2026-10-08 a `/mold` session shaped an RRSI-style improvement loop for this repository's harness sources. Session analytics supplies the evidence. The session chose a new dotfiles skill with the hill-climb driver shape (fork F-3 = A), instead of an extension of hill climb itself. An extension would break the hill-climb Iron Law and blur a clear skill. The same session chose propose-only landing: each accepted candidate becomes a PR. It also chose two evaluators: a lab replay before the PR, and a field gate over session analytics after the merge.

<speculative>The spec for that skill is not final. Check `.cheese/specs/` before you treat these choices as shipped.</speculative>
