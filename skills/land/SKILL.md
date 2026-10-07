---
name: land
description: >
  Triage bot feedback on a pull request and verify its merge into main.
  Use when the user says "land this", "land the PR", "fix bot comments and
  merge", "merge once review is complete", or invokes /land [<pr>].
  Do NOT use for a full review (/age) or human-review triage (/affinage).
disable-model-invocation: true
argument-hint: "[<pr>] [--full-review] [--no-merge] [--rounds <n>] [--include-outdated]"
license: MIT
metadata:
  author: paulnsorensen
  dispatches-agents: optional
---

# /land

Land one reviewed pull request. Triage every bot's findings, pass checks, and verify inclusion in main.
Use `gh` as the shared GitHub transport. Use an installed skill by capability, not by host slash-command syntax.
Read [`references/gh-recipes.md`](references/gh-recipes.md) before fetching feedback or watching a merge.

## Inputs

Read the flags from the user's request text. The Claude argument hint is not a required parser.

```text
/land [<pr>] [--full-review] [--no-merge] [--rounds <n>] [--include-outdated]
```

- `<pr>` accepts a number, `PR#<n>`, or URL. Default: the current branch's PR.
- `--full-review` asks CodeRabbit for a full review when CodeRabbit participates.
- `--no-merge` stops after validation and reports ready without claiming main inclusion.
- `--rounds <n>` sets the shared review, fix, and recovery limit. Default: 3.
- `--include-outdated` includes outdated threads. Otherwise, record and skip them.

## Discipline

Do not report success from a merge command or `MERGED` alone.
A changed head SHA, lost queue entry, disabled auto-merge, or stale review requires a new decision.
Verify the merge commit is an ancestor of refreshed main before reporting success.

## Flow

1. **Resolve and guard.** Read the PR state, base, head SHA, and URL.
   Require base `main`; ask before any retargeting.
   For `CLOSED` without merge, halt. For `MERGED`, skip to main verification.
   Check out the head branch when needed. Preserve unrelated worktree changes.
2. **Inventory all bot feedback.** Fetch every page of issue comments and reviews.
   Fetch every page of review threads and their comments; do not truncate bodies before triage.
   Identify REST authors by `user.type == "Bot"` or a `[bot]` login suffix.
   Identify GraphQL authors by `__typename == "Bot"`.
   Include top-level comments, review bodies, and inline threads from every bot.
   Track each source ID and its latest body or update time. Do not answer your own replies.
   Classify each item as actionable, duplicate, or notice. Record a reason for notices without reply spam.
3. **Establish review coverage.** A review only covers its `commit_id` head SHA.
   Treat CodeRabbit summaries as signals, not proof that every bot or the current SHA is clear.
   When CodeRabbit participates, retain its paused and rate-limit protocol from the recipes.
   Request its incremental or full review only when needed. Count each request as one round.
   For another bot, use only its documented trigger when configured. Do not ping an absent bot.
   Wait at most 20 minutes for a requested review. Use a host wait or bounded sleep.
   Re-fetch feedback and verify SHA coverage after the wait. Halt on API error or timeout.
4. **Decide each actionable finding.** Accept a contained fix, reject with a reason, or ask on design or scope changes.
   Use installed coder or equivalent capability for larger fixes; use an inline change when absent.
   Run the project gate for each validated head. Commit and push only actual fixes.
   Use installed plate or equivalent capability when present; otherwise use `git push`.
   Reply once to each actionable source, including rejected findings.
   Reply inside a thread for inline findings. Use a PR comment with a source link for issue and review-body findings.
   Sign replies `agent on behalf of <handle>`. Resolve only accepted, fixed threads.
   Before a reply, check its source ID and current body/update against prior decisions and replies.
   Re-triage only new or changed actionable feedback. Keep unchanged resolved findings closed.
   A bot follow-up may be actionable; distinguish it from an acknowledgement. Ignore agent replies.
5. **Validate CI and repeat.** Watch checks on the current head SHA and inspect failed job logs.
   Fix a contained failure, commit, push, and return to the full bot inventory.
   Each fix or recovery cycle consumes one shared round; waiting consumes none.
   Stop on an out-of-scope failure or exhausted rounds with the owner and open items.
   A successful terminal round is allowed after its validation completes.
6. **Merge or hold.** Select an allowed method and bind `gh pr merge` to the validated SHA.
   With `--no-merge`, report `ready; not merged` and show the command.
   Use `--auto` for protected branches or merge queues. Never use `--admin`.
   Start one 30-minute watch deadline. Do not restart it after recovery.
   Clear saved queue membership only after a verified requeue starts a new watch epoch.
7. **Watch and recover.** Read state, base, head SHA, auto-merge request, queue entry, queue head SHA, and merge commit.
   Pending `BLOCKED` with active auto-merge or queue membership is not a terminal failure.
   Inspect required checks, including checks on the saved merge-group head SHA.
   If auto-merge becomes disabled or the queue entry disappears while OPEN, inspect the timeline and failed PR or merge-group logs.
   Diagnose the reason before requeueing. Do not retry the same failure without a change.
   Apply contained fixes or conflicts using installed melt, coder, and plate capabilities, or an inline fallback.
   Commit and push actual repairs. A changed head resets bot review and CI validation before `--match-head-commit` requeue.
   Count one recovery cycle per diagnosed failure. Halt on human removal, policy, authorization, or out-of-scope changes.
   Halt on `CLOSED` without merge, wrong base, API error, deadline, or exhausted rounds.
8. **Verify main inclusion.** Require `MERGED`, `mergedAt`, and `mergeCommit.oid`.
   Refresh main and compare from merge commit to main.
   Only `identical` or `ahead` proves ancestry. Do not compare the PR head SHA; squash and rebase change it.
   If the merged change was reverted, ask the user before repair. Do not automatically revert a revert.
   Report success only after the ancestry check. Do not add unrelated post-merge gates.

## Output

```markdown
status: ok | ready; not merged | halt: <reason>
next: done | <owner or recovery capability>
artifact: <PR URL>
<rounds used; bot findings fixed / rejected / noticed / open; CI; queue or merge state; main ancestry>
| Source | Decision | Reply or reason |
|---|---|---|
```

Never force-push. Never resolve a rejected thread. Never silently retarget the base.
