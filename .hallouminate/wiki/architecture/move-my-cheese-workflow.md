# move-my-cheese workflow — landing a set of PRs

`claude/workflows/move-my-cheese.js` lands a set of open PRs or stacks. It finds out what each PR is for, finds the tensions between them, plans the landing, and drives the final PRs to ready or merged. The 2026-10 redesign replaced the per-PR rescue flow (restack, fix CI, age, cure). That flow treated each PR alone and could not supersede or combine PRs.

## Flow

1. **Recon.** One haiku agent indexes the open PRs. Code expands each stack from any member (base equals another PR's head, both ways). One haiku agent collects the detail. Code skips forks, drafts, closed PRs, unsafe refs, PRs with no full head SHA, and PRs whose base is not landable in the run. The cap is 12 PRs.
2. **Survey.** One read-only sonnet `explorer` per PR returns an intent digest (goal, approach, contracts, assumptions, completeness, risks).
3. **Tensions.** Code computes file overlaps and stack edges. One sonnet cross-reader types the tensions (`conflict`, `duplicate`, `supersedes`, `ordering`, `semantic`) and returns a `blast_radius`.
4. **Plan.** With zero tensions and only complete digests, code builds a keep-all plan, validates it, and skips the planners. Otherwise `blast_radius` maps to 1, 2, or 3 fresh opus `Plan` agents, one angle each (minimal, consolidate, risk first). An opus `judge` picks a candidate and approves, revises once, or stops.
5. **Gate.** The run returns `needs-approval` with the landing object and its digest. Run 2 passes `{ prs, plan: landing, approve: digest }`. A plan with open questions returns `needs-input` with its landing and digest instead. The caller passes `{ prs, plan: landing, approve: digest, answers }`, and one opus planner folds the answers in. That run returns `needs-approval` with a fresh digest, or `needs-input` again when questions remain. It never executes. To change an approved plan, the caller passes `{ prs, plan: landing, approve: digest, revise: "<change>" }`, alone or with `answers`. One planner folds the change in, the advisor reads the result, and the run returns a fresh digest.
6. **Assemble.** One sonnet agent per target branch, in dependency waves, with local commits only. Each round of a builder, a continuation included, starts in a fresh isolated worktree on a detached HEAD. It records progress on `mmc/<digest8>/<branch>` with `git update-ref`. A kept PR that needs no restack gets no agent.
7. **Verify.** One isolated agent merges all targets on a detached HEAD and pins the result to `mmc/<digest8>/integrate-<round>`. One `judge` per non-CI criterion then runs in that integration worktree, one after another. Each judge confirms `git -C <path> rev-parse HEAD` and runs the check with `cd <path> && bash -c '<check>'`.
8. **Publish.** One sonnet agent pushes each rebuilt target from the session checkout as `<local>:refs/heads/<branch>`, with `--force-with-lease` against the recon SHA for existing PRs. It opens new PRs with `gh pr create`. Code validates the report; publish never reruns.
9. **Review.** This step is pipelined per PR: aged-marker scope decision, `/age`, `/cure`, re-age, marker stamp, then bounded polls. Each poll waits for checks and runs `/affinage --auto --no-age --plate` when work remains.
10. **Land** (`land:true`). The final heads are verified again and the advisor gives a `done` approval. The run then merges bottom-up. After a parent merges, each child is moved with `git rebase --onto origin/<default> origin/<parent>`.

## Decisions

- **The approval gate takes two runs.** The Workflow runtime cannot pause for input. The digest is FNV-1a over a key-sorted serialization of `{inputs, recon, tensions, plan}`. It binds approval to the exact plan, so an edit after approval blocks the run. It detects edits; it does not stop a hostile caller. A plan with open questions cannot execute.
- **Answers go back through the digest (#1272).** `needs-input` returns the digest, so `answers` binds to the exact landing that asked. Keys are the question text or its 1-based number. Code validates the answers before the first agent. One planner revision applies them, so survey and tensions do not run again. The advisor reads the answered plan, because an answer can restructure targets. The user then approves it through the normal gate. When the advisor cannot settle the plan stage, each candidate comes back with its own landing and digest, so the user can approve one directly. The rejected alternative was a code-only fold into `summary`; it cannot restructure targets when an answer requires that.
- **Every advisor revise gets a planner (#1274).** One helper, `advisePlans`, runs the plan advisor for new, answered, and revised plans. A `revise` verdict gets one planner revision that receives the concerns and the guidance, and the advisor then reads the revised plan. So the user approves the plan that the advisor read last. Before #1274, an answered plan with a `revise` verdict came back unchanged, and the user could not apply the named fix. Only the workflow can compute a digest, so an agent cannot hand-edit `args.plan`; the `revise` arg is the edit path. A fold skips the validation of the passed plan and passes its errors to the planner, so `revise` also repairs an approval that a newer check rejects. A failed revision returns the advised candidates with the reason instead of blocking.
- **Staleness.** Run 2 returns `needs-replan` when any head SHA or the PR set changed. A moved default branch blocks only a reshaping plan (modify, supersede, close, or new target). A keep-only plan just restacks.
- **The run fails closed.** A dead survey or tension agent blocks the run. Zero tensions must be a positive finding, not a missing result.
- **Auto asks whenever another author is in the run.** Review, cure, `/affinage`, and land push to and merge every PR in the run, including kept ones, and stack expansion can add any author's PR. So `auto:true` stops at `needs-approval` when any PR in the run is not the viewer's.
- **Run-scoped refs.** No agent checks out a PR branch by name, so the user's local branches, unpushed commits, and checkouts stay untouched. Builders record progress on `mmc/<digest8>/<branch>`; salvage reads only that ref. Review writers push with `HEAD:<branch>`.
- **Each writer gets its own worktree; state moves through refs.** `claude/hooks/worktree-guard.js` roots writes in the agent's session cwd, and a Bash `cd` does not persist. So every stage that edits (builder rounds, cure, `/affinage`, restack) runs with `isolation: 'worktree'`. No writer edits in a directory that another agent returned. Git refuses a branch that another worktree has checked out. So builders, cure, and restack keep HEAD detached. Age and re-age pin a detached HEAD at an exact SHA. `/affinage` needs a branch for `/plate`, so each round checks out its own `mmc/<digest8>/<branch>--<phase>-<round>` with `origin/<branch>` as upstream. The prompt tells `/plate` to push with `HEAD:<branch>`. Cure reads the age report by absolute path, copies it into its own tree, and pushes its own commits. Re-age then pins the pushed cure head. Finalize needs no worktree: it stamps the marker from that SHA and remote-tracking refs. The rejected alternative was to allow `<main>/.claude/worktrees/*` in the guard. That is smaller, but it is a guard change.
- **Judges read the integration worktree (#1269).** The `judge` contract forbids checkout, so an isolated judge sat at the main checkout HEAD and returned `integration-missing` for every criterion. Judges are read-only, so they share the integrate worktree in sequence. The guard does not apply, because judges do not write.
- **Checks run where their config lives (#1270).** Planners write each check as one bash command from the repository root. A check for a workspace member starts with `cd <member> &&`, quotes its globs, and puts options before `--`. Judges run the check under `bash -c`, because the Bash tool uses zsh, and zsh fails an unmatched glob before the command starts. Judges never rewrite a check.
- **Supersede and close.** Without `land`, a superseded PR gets a comment and becomes a draft after its replacement is ready. It closes only after the replacement merges. The workflow never deletes branches and never passes `--admin`. Comments go through `--body-file -` with a quoted heredoc.
- **Merge safety.** Each merge uses `--match-head-commit` with a full SHA from a fresh status agent that code checks for readiness. With a merge queue, the merge agent uses `--auto`, and code polls until the PR is `MERGED` before it moves the children.
- **Verify runs when anything could compose wrongly.** That is any reshaping disposition, a new target, side-by-side targets, a tension, or a non-CI criterion. Only a single stack of kept PRs with CI-only criteria skips it. The integrate result must name every target as merged or conflicted.
- **Criteria checks are code-gated.** A judge runs each check, so `checkPlan` rejects network access, shell pipes, file redirects, `tee`, inline interpreter code, in-place edits, git mutations (also after `-C <path>`), file removal, package installs, and mutating `gh` calls. This denylist is defense in depth; the judge definition is the other guard. Run 2 runs the same validator on the passed plan.
- **A check must be able to fail (#1274).** `grep` and `rg` exit 2 on a missing file, and a leading `!` turns that into a pass. So `checkPlan` rejects a negated search that has no `test -e`, `test -f`, `test -d`, or `[ -e ... ]` before it. Code cannot know which paths exist, so the planner and advisor prompts also require that each path a check reads exists on the default branch or comes from a target.
- **The aged marker is trusted only from the viewer.** Recon reads only the viewer's comments. A marker without full 40-hex `sha` and `patch` reads as no marker, so a forged comment cannot skip `/age` or reach a shell step.
- **Cure never asks.** Cure and `/affinage` always use `--auto --stake medium+`. That floor selects blocker, high, and medium findings, plus each low with `fix-cost-now: contained`. Age reports `has_cheap_lows`, so contained lows alone also start a cure. The prompts forbid a selection gate. A finding is deferred only for a false premise or a conflict.
- **Cure fixes must reach the remote.** Cure pushes with a fast-forward `git push origin HEAD:<branch>`. When cure commits but reports no push or no full head SHA, the review fails before re-age instead of polling a head without the fix.
- **A successful run cleans up.** The runtime removes only unchanged isolated worktrees. On `ready` or `landed`, one haiku agent removes each recorded scratch worktree under `.claude/worktrees/` and each worktree on an `mmc/<digest8>/` branch. It then deletes the `mmc/<digest8>/` refs. A failed or partial run keeps them for inspection and salvage.
- **A spent budget still ends in a report.** `agent()` throws once the token budget is spent. Code checks the budget floor before Verify, before Publish, and before each merge. Land runs inside try/catch, so a throw returns `partial` with the reason instead of ending the script after some merges.
- **Every stage result passes a code check.** Status, age, re-age, finalize, prep, merge polls, and cleanup go through `typed()`, so a `null` from a cheap stage gets one redo. Status needs a full head SHA. Re-age must review the cure commits. A cure that stops with no commits fails the review, so its selected findings are never dropped in silence. A marker that the finalizer cannot write costs a full re-age next run, so code logs it and keeps the PR.
- **Mechanical reads are exact commands.** Recon and status take CI state from `gh pr checks --json bucket` with a fixed `jq` mapping, and the unresolved-thread count from one GraphQL query. Code caps the PR body at 1500 characters and lists every PR pair for the tensions reader. Code shell-quotes each criterion check, and the judge runs `cd <path> && bash -c <quoted check>` unchanged. Each judge reports `tree_clean`, and a dirty tree shows in the verdict evidence.
- **The done advisor gates every success.** Without `land`, the advisor approves before the run converts superseded PRs to drafts and before it reports `ready`. With `land`, it approves before the first merge.
- **Stage branches survive a failed run.** `/affinage` checks out its per-round branch with `--ignore-other-worktrees`, because a kept worktree from a failed run with the same digest can still hold that name.
- **Readiness is a code predicate.** `merge_state` is an enum of the GitHub `mergeStateStatus` values. It needs `OPEN`, CI `pass`, `CLEAN` or `HAS_HOOKS`, no unresolved threads, and no `CHANGES_REQUESTED`. CI `none` waits unless `allowNoChecks:true`. `DRAFT` reports `draft`. `BLOCKED` with everything else green reports `awaiting-review`. The poll stops as `stalled` when `/affinage` leaves the status fingerprint unchanged.
- **Model tiers.** Planners, the advisor, age, re-age, and `/affinage` run on opus. Survey, tensions, builders, publish, cure, and restack run on sonnet. Recon, status, finalize, merge, and mark run on haiku. Publish moved from opus to sonnet because code validates its whole report.
- **ADR-4 tension.** [[adr/subagent-routing-overhaul]] ADR-4 asks for thin workflow wrappers. This script keeps code to mechanical work: argument checks, expansion, overlaps, validation, the digest, the readiness predicate, and bounds. Agents make every judgment. The planner count comes from the cross-reader's `blast_radius` artifact. The age fan-out threshold below still predates ADR-5's `age-route`; that is known drift.

## Known gaps

- A non-land run followed by a land run of the same approval does not work. The superseded PRs are drafts, and the new target branch already has an open PR. Land in the first run, or plan again.
- Land merges a head that `/affinage` or a child restack changed after the final verification. Only CI gates that head.
- When land stops partway, superseded PRs stay open even when their replacement merged.
- After a merge-based rebuild, the incremental age scope `<marker sha>..HEAD` also covers the default-branch changes that the merge brought in.
- Each re-run still passes the whole landing object (about 25 KB) in `args.plan`. A plan file path or run id in its place is not built (#1274, optional part).
- The existence-test rule is lexical. It does not prove that the guard names the same path as the grep, and it does not catch `cat <missing> | grep` pipelines.
- Judges depend on the runtime keeping the integration worktree, which has new merge commits. A 2026-10-11 live run confirmed that it stays.
- **Fixed (#1268): non-isolated writers could not edit a shared worktree.** `worktree-guard.js` takes its root from the session cwd, so a writer that `cd`-ed into another agent's worktree had its `tilth_write`, Edit, and Write calls blocked. A probe on 2026-10-11 confirmed this from a T3 worktree. Every writer now runs isolated (see Decisions). No live T3 run has confirmed the fix yet.
- **Not a gap: the age-fanout reconcile write.** The guard allows any path inside a `.cheese/` directory, so reconcile may write `<prep worktree>/.cheese/age/<slug>.md` from a non-isolated session. The prompt gives the absolute path, because a `cd` does not carry into `tilth_write`. See `claude/workflows/age-fanout.js`.
- `/plate` on a stage-owned `mmc/...` branch is not confirmed in a live run. It finds the PR through the upstream, and the prompt pins its push to `HEAD:<branch>`.
- **Reviewer dispatches need the contract line (#1271).** The `reviewer` agent type returns `blocked: missing-contract` unless the prompt has `Review mode: severity-report`. `reviewerPrompt` and the age-fanout prompts send the line. Age-fanout workers now return a `status`; a lost or blocked dimension gets one retry, and a dimension with no review blocks the fan-out, so the PR falls back to one full reviewer.

## Why a PR-comment marker (not git notes or a local artifact)

Each aged PR carries one upserted comment:

```
<!-- move-my-cheese:aged sha=<head-sha> patch=<patch-id> dirty=<0|1> -->
```

A git note stays local unless you push it, and GitHub does not show it. A durable-corpus artifact is machine-local. The marker must survive across machines and disposable worktrees, and it gives visible provenance on the PR.

## Why the marker records both sha and patch-id

The Age stage decides its scope in four steps, in order:

1. Marker `dirty=1` → **full** `/age`. A skip or incremental review would hide the open medium+ findings.
2. `git diff origin/<base>...HEAD | git patch-id --stable` equals the marker `patch=` → the content is unchanged (for example, a restack) → **skip** `/age`.
3. Marker `sha=` is an ancestor of HEAD → **incremental** `/age <sha>..HEAD`.
4. Otherwise → **full** `/age origin/<base>...HEAD`.

The sha alone forces a full re-age after every restack. The patch-id alone cannot scope an incremental review. Code also skips the age agent when the marker sha equals the head and the marker is clean.

## Threshold-gated dimension fan-out (ADR-007)

A full review with no clean marker and more than 15 files or 800 changed lines runs `workflow('age-fanout', ...)` instead of one reviewer. When the child returns non-ok or throws, the PR falls back to one reviewer. Rationale: [[adr/cheese-factory-workflow]] (ADR-007).

Related: [[architecture/saved-workflows]] (deploy path and harness), tests in `tests/workflows/move-my-cheese.test.mjs` (offline harness, `just smoke`).

_Source: claude-workflows redesign session 2026-10-11 (advisor gate + reviewer pass with 8 harness probes); fixes for #1268–#1272 and #1274 · Updated: 2026-10-11 · Supersedes: the per-PR rescue design (Discover → Recon → Rescue → Age → Cure → Finalize)._
