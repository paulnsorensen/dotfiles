# Harness climb: measured edits to the harness

The `harness-climb` skill runs an RRSI-style improvement loop on dotfiles-owned harness sources. It uses session analytics as evidence. It runs one round per invocation, with the driver shape from [[hill-climb-ratchet]]. Spec: `harness-climb` (mold spec, 2026-10-08).

A round runs the first step that applies: stop check, field gate due, analyze, propose, critic, lab, freeze, publish, ledger. Local state lives in `.harness-climb/<thread>/` (gitignored). Committed gate files live in `harness-climb/gates/<thread>-r<t>.json`.

## Decisions

**Propose only.** Each accepted candidate becomes a PR through `/plate`. The skill never merges, never runs `dots sync`, and never reverts on its own. A `revert` verdict opens a revert PR. Every edit changes every later session in several harnesses, and the field gate is weak, so a human merges.

**Two evaluators.** A lab runs before the PR only where a lab exists: `skillz autoimprove` for a skill with `evals/autoimprove.json`. Freeze derives the contract from that file, not from a flag. Every other component records `lab: held`. A field gate runs after merge on every change.

**The gate file is frozen before merge.** It holds the targeted query, the guard composite version, the minimum sessions, the soak length, the sync grace, and `token_per_gain`. The field gate reads it from the merge commit with `git show`, so a later edit or a PR body cannot move it. Freeze dry-runs the query and refuses a `;`, because an invalid query would only fail after the soak.

**The guard composite is a code constant.** It holds tool-error rate, permission denials, and stop-hook blocks per session. Codex records only tool-error rate, so the other two members are `n/a` for Codex and never count as a pass. Tokens per turn are not a guard. Only the cost rule (`cost <= token_per_gain * gain`) judges them.

**Unpaired Welch test at 2·SE.** The before and after windows hold different sessions. The threshold matches skillz `_gate.py`. One verdict per harness, then `revert` wins, then `keep` over `keep-cheaper`, else `inconclusive`.

**The critic cannot edit itself.** The scope check denies `skills/harness-climb/` and `skills/session-analytics/` with category `self-edit`. The skill runs its script from the loaded skill directory, not from the proposal checkout.

**Leakage denylist from real prompts.** The critic builds n-grams from Claude and Codex user prompts and checks added lines only. Slash-command arguments count; only the command token is dropped. Project names match as whole tokens with a stop-list for generic directory words. Substring matching rejected most rounds. Rejection output never holds prompt or project text.

## Gotchas

**The edit takes effect at the sync, not at the merge.** `dots sync` appends `<epoch> <HEAD sha>` to `$DOTFILES_STATE_DIR/sync-history.log` (see [[operations/sync-and-chezmoi]]). The after window starts at the first logged sync whose commit contains the merge. Before the sync grace ends with no such sync, the gate returns `not-due` and records nothing. After the grace it returns `inconclusive` with reason `sync-late`.

**Soak hold on harness pins.** The required CI job `soak-check` fails a PR that changes the `aqua:anthropics/claude-code` or `aqua:openai/codex` pin while a soak window is open. CI cannot read the local sync history, so the CI window opens at the merge of a gate file and closes after sync grace plus soak length. To override a hold, add the `harness-climb/soak-override` label, then re-run the CI workflow. The job reads labels from the API at run time. Label events do not trigger CI, because a label-only run could post a green `test` check over a red one.

**Ledger pending resolves the merge.** The ledger is append-only, and the latest line per round wins. `harness_climb.py ledger pending` finds each pending round's merge on main from the gate file path. An unmerged branch commit never counts as the merge.

## Deployment

The skill lives in `skills/harness-climb/` and Claude selects it through `claude.skills` in `chezmoi/.chezmoidata/claude.yaml`. Tests: `tests/harness-climb.bats` wraps `tests/harness_climb/`. Session analytics gained `sessions.version` and Codex `model_turns` token rows for this loop; see `skills/session-analytics/references/canonical-schema.md`.
