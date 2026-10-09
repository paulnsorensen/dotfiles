# Field gate

The field gate measures a merged change on later claude and codex sessions.
It reads every setting from the gate file in the merge commit. A working-tree edit or a PR body changes nothing.

## Gate file

`freeze` writes `harness-climb/gates/<thread>-r<n>.json` and commits it with the change:

- `thread`, `round`, `component` — identity of the round.
- `targeted_query` — SQL on the session database. It returns the columns `harness`, `sessionId`, and `value`. The gate averages `value` per session.
- `direction` — `lower` or `higher`. It says which way `value` must move for a gain.
- `guard_composite_version` — the guard set that applies. An unknown version gives `inconclusive`.
- `min_sessions`, `soak_days`, `sync_grace_days`, `token_per_gain` — gate thresholds.

Scope the targeted query to `harness IN ('claude','codex')`.

## Windows

- The after window starts at the first line of `sync-history.log` whose SHA contains the merge commit. It lasts `soak_days`.
- No such line, and `now` is not past `sync_grace_days` after the merge commit time, gives `not-due`. The ledger stays `pending`.
- No such line after that grace gives `inconclusive` with reason `sync-late`.
- A sync later than `sync_grace_days` after the merge gives `inconclusive` with reason `sync-late`.
- Before the after window ends, the result is `not-due`.
- A sync inside the after window whose SHA lacks the merge commit gives `inconclusive` with reason `sync-regressed`. Every clone and worktree writes the log, so that line means a deploy dropped the change.
- A `not-due` result is never a ledger verdict.
- A session database with no `version` column gives `inconclusive` with reason `version-unavailable`.
- The before window ends where the after window starts. It begins `soak_days` earlier.
- A harness version change inside the two windows does not clip a window. The gate keeps the dominant version: the version with at least `min_sessions` sessions in both windows and the most sessions in total. It drops the sessions of other versions. The result reports `version`, `versions`, and `excluded`, the count of dropped sessions.
- No version with `min_sessions` in both windows gives `inconclusive` with reason `version-changed`.
- A session database that the gate cannot refresh gives `inconclusive` with reason `db-stale`.

## Statistics

The gate compares window means per harness with a Welch test at two standard errors.

- A target gain beyond two standard errors, with the guards intact, gives `keep`.
- A target move the wrong way beyond two standard errors gives `revert` with reason `target`.
- A guard regression gives `revert` and names the guard.
- A token rise larger than `token_per_gain` times the gain gives `revert` with reason `token-cost`.
- No target effect and a token drop beyond two standard errors gives `keep-cheaper`.
- No target effect and no token drop gives `inconclusive` with reason `no-effect`.
- Fewer than `min_sessions` in either window gives `inconclusive` with the counts.
- Tokens are never a guard. Codex records no permission denials or stop-hook blocks, so those guards are `n/a` for codex. `n/a` is never a pass.

The candidate verdict combines the two harness verdicts. `revert` beats `keep`, `keep` beats `keep-cheaper`, and anything else is `inconclusive`.

## Revert

A `revert` verdict sets `action` to `open-revert-pr`. The gate changes no branch, no HEAD, and no file. Open the revert PR through `/plate`. A human merges it.
