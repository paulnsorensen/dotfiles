# move-my-cheese workflow — landing a set of PRs

`claude/workflows/move-my-cheese.js` lands a set of open PRs or stacks. It finds out what each PR is for, finds the tensions between them, plans the landing, and drives the final PRs to ready or merged. The 2026-10 redesign replaced the per-PR rescue flow (restack, fix CI, age, cure). That flow treated each PR alone and could not supersede or combine PRs.

## Flow

1. **Recon.** One haiku agent indexes the open PRs. Code expands each stack from any member (base equals another PR's head, both ways). One haiku agent collects the detail. Code skips forks, drafts, closed PRs, unsafe refs, PRs with no full head SHA, and PRs whose base is not landable in the run. The cap is 12 PRs.
2. **Survey.** One read-only sonnet `explorer` per PR returns an intent digest (goal, approach, contracts, assumptions, completeness, risks).
3. **Tensions.** Code computes file overlaps and stack edges. One sonnet cross-reader types the tensions (`conflict`, `duplicate`, `supersedes`, `ordering`, `semantic`) and returns a `blast_radius`.
4. **Plan.** With zero tensions and only complete digests, code builds a keep-all plan, validates it, and skips the planners. Otherwise `blast_radius` maps to 1, 2, or 3 fresh opus `Plan` agents, one angle each (minimal, consolidate, risk first). An opus `judge` picks a candidate and approves, revises once, or stops.
5. **Gate.** The run returns `needs-approval` with the landing object and its digest. Run 2 passes `{ prs, plan: landing, approve: digest }`. Code checks the digest before any agent runs.
6. **Assemble.** One sonnet agent per target branch, in dependency waves, with local commits only. A kept PR that needs no restack gets no agent.
7. **Verify.** One agent merges all targets on a detached HEAD and pins the result to `mmc/<digest8>/integrate-<round>`. One `judge` per non-CI criterion checks out that commit in its own isolated worktree and runs the check.
8. **Publish.** One sonnet agent pushes each rebuilt target as `<local>:refs/heads/<branch>`, with `--force-with-lease` against the recon SHA for existing PRs. It opens new PRs with `gh pr create`. Code validates the report; publish never reruns.
9. **Review.** This step is pipelined per PR: aged-marker scope decision, `/age`, `/cure`, re-age, marker stamp, then bounded polls. Each poll waits for checks and runs `/affinage --auto --no-age --plate` when work remains.
10. **Land** (`land:true`). The final heads are verified again and the advisor gives a `done` approval. The run then merges bottom-up. After a parent merges, each child is moved with `git rebase --onto origin/<default> origin/<parent>`. A head that moved after review is checked again before it merges. Each superseded PR closes as soon as its own replacement merges.
11. **Stamp.** One haiku agent records, on each open target, the head the run last saw.

## Decisions

- **The approval gate takes two runs.** The Workflow runtime cannot pause for input. The digest is FNV-1a over a key-sorted serialization of `{inputs, recon, tensions, plan}`. It binds approval to the exact plan, so an edit after approval blocks the run. It detects edits; it does not stop a hostile caller. A plan with open questions returns `needs-input` with no digest and cannot execute.
- **Staleness.** Run 2 returns `needs-replan` when any head SHA or the PR set changed. A moved default branch blocks only a reshaping plan (modify, supersede, close, or new target). A keep-only plan just restacks.
- **The same approval resumes from its own stamps.** Every PR the run pushes to, opens, or drafts gets one upserted viewer comment `<!-- move-my-cheese:landing digest=<d> -->`. At the end of a run, each open target's comment also records `head=<sha>`, the head the run last saw. The stamp agent writes it only when the live head still matches. Recon reads the marker only from the viewer's comments, never from a PR body. A later run of the same approval then:
  - keeps its own drafts as inputs instead of skipping them;
  - accepts a moved head only when it equals this approval's stamp, so a push by anyone else after the stamp still returns `needs-replan`;
  - adopts an open PR on a new target's branch only when the viewer opened it in this repository and the stamp matches its head; any other PR on that branch blocks the run;
  - blocks an adopted PR that would need a rebuild (base changed, or its parent was rebuilt), because publish has no lease for a new target's branch;
  - gives a modified PR whose stamp matches a rebase-only job, so the brief is not applied twice;
  - skips the moved-default-branch check once the approval has started.
  So a non-land run followed by `land:true` continues where the first run stopped. Resume after a partial land returns `needs-replan`, because merged and closed inputs leave the PR set.
- **The run fails closed.** A dead survey or tension agent blocks the run. Zero tensions must be a positive finding, not a missing result.
- **Auto asks whenever another author is in the run.** Review, cure, `/affinage`, and land push to and merge every PR in the run, including kept ones, and stack expansion can add any author's PR. So `auto:true` stops at `needs-approval` when any PR in the run is not the viewer's.
- **Run-scoped local branches.** No agent checks out a PR branch by name. Each works on `mmc/<digest8>/<branch>` and pushes with `HEAD:<branch>`. That keeps the user's local branches, unpushed commits, and checkouts untouched, and salvage can only find this run's branches.
- **Supersede and close.** Without `land`, a superseded PR gets a comment and becomes a draft after its replacement is ready. With `land`, it closes as soon as its replacement merges. When landing stops partway, every PR whose replacement has not merged becomes a draft. Dropped (`close`) PRs close only after a full landing. A PR this approval already drafted gets no second comment. The workflow never deletes branches and never passes `--admin`. Comments go through `--body-file -` with a quoted heredoc.
- **Merge safety.** Each merge uses `--match-head-commit` with a full SHA from a fresh status agent that code checks for readiness. With a merge queue, the merge agent uses `--auto`, and code polls until the PR is `MERGED` before it moves the children.
- **A moved head gets a full re-check before it merges.** When the head at merge time differs from the head that review saw, after an `/affinage` push or a child restack, the run re-ages it with a full review against the default branch. A restack or an `/affinage` merge can pull base changes into an incremental range. When Verify applies, it also integrates that target onto the current default branch. It re-runs every criterion whose satisfying targets have all merged or are this target, so landed outcomes are checked again. New findings or a failed check stop landing as `changed-after-verify`. There is one re-check per target; a later move fails `--match-head-commit`.
- **A rebuilt branch gets a full review.** After this run rebuilds a branch, a `<marker sha>..HEAD` range can hold base-branch changes, so Age may skip on an unchanged patch-id or review the full diff, but never scopes incrementally.
- **Verify runs when anything could compose wrongly.** That is any reshaping disposition, a new target, side-by-side targets, a tension, or a non-CI criterion. Only a single stack of kept PRs with CI-only criteria skips it. The integrate result must name every target as merged or conflicted.
- **Criteria checks are code-gated.** A judge runs each check, so `checkPlan` rejects network access, shell pipes, file redirects, `tee`, inline interpreter code, in-place edits, git mutations (also after `-C <path>`), file removal, package installs, and mutating `gh` calls. This denylist is defense in depth; the judge definition is the other guard. Run 2 runs the same validator on the passed plan.
- **The aged marker is trusted only from the viewer.** Recon reads only the viewer's comments. A marker without full 40-hex `sha` and `patch` reads as no marker, so a forged comment cannot skip `/age` or reach a shell step.
- **Cure fixes must reach the remote.** When cure commits, finalize must report a push and a full head SHA, or the review fails instead of polling a head without the fix.
- **Readiness is a code predicate.** It needs `OPEN`, CI `pass`, `CLEAN` or `HAS_HOOKS`, no unresolved threads, and no `CHANGES_REQUESTED`. CI `none` waits unless `allowNoChecks:true`. `DRAFT` reports `draft`. `BLOCKED` with everything else green reports `awaiting-review`. The poll stops as `stalled` when `/affinage` leaves the status fingerprint unchanged.
- **Model tiers.** Planners, the advisor, age, re-age, and `/affinage` run on opus. Survey, tensions, builders, publish, cure, and restack run on sonnet. Recon, status, finalize, merge, mark, and stamp run on haiku. Publish moved from opus to sonnet because code validates its whole report.
- **ADR-4 tension.** [[adr/subagent-routing-overhaul]] ADR-4 asks for thin workflow wrappers. This script keeps code to mechanical work: argument checks, expansion, overlaps, validation, the digest, the readiness predicate, and bounds. Agents make every judgment. The planner count comes from the cross-reader's `blast_radius` artifact.

## Live test (2026-10-11)

A plan-only run of the worktree script on #1151 and #1261 (two oh-my-pi pin bumps) ran 13 agents with no errors and made no remote changes. The planner found that `main` was already at v18.9.0 through Renovate. It closed #1151 as a downgrade, modified #1261 to rebase onto `main`, and flagged a duplicate Renovate branch. The advisor asked for a stronger criterion twice: a three-dot diff hides drift from current `main`, and an ancestry check proves the rebase happened. With `advisorRevisions: 1`, the run returned `needs-input` with the candidate and the advice.

## Known gaps

- The age fan-out decision still uses the inherited size threshold, not ADR-5's `age-route`. The router needs a full review context record that only a reviewer should assemble, so the fix belongs in easy-cheese: [easy-cheese#766](https://github.com/paulnsorensen/easy-cheese/issues/766).
- The runtime rule for removing isolated worktrees is not confirmed. Judges therefore check out the pinned integration commit in their own worktrees instead of reusing the integrate agent's worktree.
- `dots sync` deploys from the main clone, not from a worktree. Test an unmerged version through `Workflow({ scriptPath })` instead of syncing from the worktree, which would undo uncommitted chezmoi work in the main clone.

## Why a PR-comment marker (not git notes or a local artifact)

Each aged PR carries one upserted comment:

```
<!-- move-my-cheese:aged sha=<head-sha> patch=<patch-id> dirty=<0|1> -->
```

A git note stays local unless you push it, and GitHub does not show it. A durable-corpus artifact is machine-local. The marker must survive across machines and disposable worktrees, and it gives visible provenance on the PR. The landing marker uses the same channel for the same reasons.

## Why the marker records both sha and patch-id

The Age stage decides its scope in four steps, in order:

1. Marker `dirty=1` → **full** `/age`. A skip or incremental review would hide the open medium+ findings.
2. `git diff origin/<base>...HEAD | git patch-id --stable` equals the marker `patch=` → the content is unchanged (for example, a restack) → **skip** `/age`.
3. Marker `sha=` is an ancestor of HEAD → **incremental** `/age <sha>..HEAD`. A branch this run rebuilt skips this step.
4. Otherwise → **full** `/age origin/<base>...HEAD`.

The sha alone forces a full re-age after every restack. The patch-id alone cannot scope an incremental review. Code also skips the age agent when the marker sha equals the head and the marker is clean.

## Threshold-gated dimension fan-out (ADR-007)

A full review with no clean marker runs `workflow('age-fanout', ...)` instead of one reviewer when the PR has more than 15 changed files or more than 800 changed lines (strictly greater: exactly 15 files or 800 lines stays on one reviewer). When the child returns non-ok or throws, the PR falls back to one reviewer. Rationale: [[adr/cheese-factory-workflow]] (ADR-007).

Related: [[architecture/saved-workflows]] (deploy path and harness). Tests live in `tests/workflows/move-my-cheese.{plan,execute,land,resume}.test.mjs` with shared builders in `move-my-cheese.fixtures.mjs` (offline harness, `just smoke`).

_Source: claude-workflows redesign session 2026-10-11 (advisor gate, two reviewer passes, gap fixes, CodeRabbit review on PR #1264, live plan-only run) · Updated: 2026-10-11 · Supersedes: the per-PR rescue design (Discover → Recon → Rescue → Age → Cure → Finalize)._
