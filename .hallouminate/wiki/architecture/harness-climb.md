# Harness climb: measured edits to the harness

The `harness-climb` skill runs an RRSI-style improvement loop on dotfiles-owned harness sources. It uses session analytics as evidence. It runs one round per invocation, with the driver shape from [[hill-climb-ratchet]]. Spec: `harness-climb` (mold spec, 2026-10-08).

A round runs the first step that applies: stop check, field gate due, analyze, propose, critic, lab, freeze, publish, ledger. Local state lives in `.harness-climb/<thread>/` (gitignored). Committed gate files live in `harness-climb/gates/<thread>-r<t>.json`.

## Decisions

**Propose only.** Each accepted candidate becomes a PR through `/plate`. The skill never merges, never runs `dots sync`, and never reverts on its own. A `revert` verdict opens a revert PR. Every edit changes every later session in several harnesses, and the field gate is weak, so a human merges.

**Two evaluators.** A lab runs before the PR only where a lab exists: `skillz autoimprove` for a skill with `evals/autoimprove.json`. Freeze derives the contract from that file, not from a flag. Every other component records `lab: held`. A field gate runs after merge on every change.

**Freeze commits the gate file before merge.** It holds the targeted query, the guard composite version, the minimum sessions, the soak length, the sync grace, and `token_per_gain`. The field gate reads it from the merge commit with `git show`, so a later edit or a PR body cannot move it. Freeze dry-runs the query and refuses a `;`, because an invalid query would only fail after the soak.

**The guard composite is a code constant.** It holds tool-error rate, permission denials, and stop-hook blocks per session. Codex records only tool-error rate, so the other two members are `n/a` for Codex and never count as a pass. Tokens per turn are not a guard. Only the cost rule (`cost <= token_per_gain * gain`) judges them.

**Unpaired Welch test at 2·SE.** The before and after windows hold different sessions. The threshold matches skillz `_gate.py`. One verdict per harness, then `revert` wins, then `keep` over `keep-cheaper`, else `inconclusive`.

**Dominant version, not clipping.** A harness version change inside the windows does not shorten the before window. The gate keeps the version with at least `min_sessions` sessions in both windows and the most sessions in total. It drops other versions and reports `excluded`. When no version meets that bar, the verdict is `inconclusive` with reason `version-changed`.

**Token cost reads context tokens.** The cost rule uses `model_turns.context_tokens + output_tokens` per turn. For Claude, `context_tokens` adds cache reads and cache creation to `input_tokens`. Codex `input_tokens` already includes cached tokens. Before PR #1224, Claude cost used `input_tokens` only, and the cache held almost all context (live averages: input 8, cache read 130,854). So a prompt-prefix edit had no visible cost.

**Sub-agent sessions do not count.** A Codex sub-agent rollout keeps its own session id and records `sessions.parent_session_id`. `hc_db.load_rows` excludes these sessions, because they are correlated with their parent and would shrink the standard error. Claude sidechains already share the parent `sessionId`.

**Freeze checks the query for leakage.** The critic never sees `targeted_query`, and the freeze commits it to a public repository. So the freeze runs the leakage denylist on the query and refuses a hit without echoing the text. A database failure reports as `session database unavailable`, not as a bad query (`hc_db.DbError`).

**STOP is one check.** `main()` checks the thread STOP file before it resolves any ref. `ledger stop-check` writes STOP with reason `diminishing-returns` after three field verdicts with no `keep`. `critic --denylist` exists only when `HARNESS_CLIMB_TEST_DENYLIST` is set.

**The critic cannot edit itself.** The scope check denies `skills/harness-climb/` and `skills/session-analytics/` with category `self-edit`. The skill runs its script from the loaded skill directory, not from the proposal checkout.

**Leakage denylist from real prompts.** The critic builds n-grams from Claude and Codex user prompts and checks added lines only. The denylist skips every prompt that starts with `<`, so `<command-args>` text does not enter it yet. This is a known issue. Project names match as whole tokens with a stop-list for generic directory words. Substring matching rejected most rounds. Rejection output never holds prompt or project text.

## Gotchas

**The edit takes effect at the sync, not at the merge.** `dots sync` appends `<epoch> <HEAD sha>` to `$DOTFILES_STATE_DIR/sync-history.log` (see [[operations/sync-and-chezmoi]]). The after window starts at the first logged sync whose commit contains the merge. Before the sync grace ends with no such sync, the gate returns `not-due` and records nothing. After the grace it returns `inconclusive` with reason `sync-late`. Every clone and worktree writes the same log. When a sync inside the after window has a SHA without the merge, the gate returns `inconclusive` with reason `sync-regressed`. A sync from a dirty tree never counts as deploying a merge.

**Soak hold on harness pins.** The required CI job `soak-check` fails a PR that changes the `aqua:anthropics/claude-code` or `aqua:openai/codex` pin while a soak window is open. CI cannot read the local sync history. So the CI window opens at the merge of a gate file and closes after sync grace plus soak length. To override a hold, add the `harness-climb/soak-override` label. Then re-run the CI workflow. The job reads labels from the API at run time through `bin/ci-soak-gate labels`. Label events do not trigger CI, because a label-only run could post a green `test` check over a red one. `bin/ci-soak-gate guard` fails a PR that changes both `soak_check.py` and the mise pin file, so a PR cannot weaken its own hold. The required aggregate `test` job runs `bin/ci-soak-gate assert`, so it needs a sparse checkout of that one file.

**Ledger pending resolves the merge.** The ledger is append-only, and the latest line per round wins. `harness_climb.py ledger pending` finds each pending round's merge on main from the gate file path. An unmerged branch commit never counts as the merge.

## Deployment

The skill lives in `skills/harness-climb/` and Claude selects it through `claude.skills` in `chezmoi/.chezmoidata/claude.yaml`. Tests: `tests/harness-climb.bats` wraps `tests/harness_climb/`. Session analytics gained `sessions.version`, `sessions.parent_session_id`, `model_turns.context_tokens`, and Codex `model_turns` token rows for this loop; see `skills/session-analytics/references/canonical-schema.md` and [[operations/session-analytics-gotchas]]. A database built before PR #1224 lacks the new columns, and `load_rows` asks for `ingest.py --force`.

_Source: PR #1224 review and cure (`.cheese/affinage/pr-1224.md`, `.cheese/cure/pr-1224.md`) · Updated: 2026-10-09_
