---
name: land
description: >
  Fix the open CodeRabbit comments on a pull request, wait for CI, and merge.
  Use when the user says "land this", "land the PR", "fix the rabbit comments
  and merge", "merge once CodeRabbit is happy", or invokes /land [<pr>].
  Do NOT use for a full review (/age), full PR triage with human reviewers
  (/affinage), or a PR that has no CodeRabbit review yet and needs one designed.
disable-model-invocation: true
argument-hint: "[<pr>] [--full-review] [--no-merge] [--rounds <n>] [--include-outdated]"
license: MIT
metadata:
  author: paulnsorensen
  dispatches-agents: optional
---

# /land

Land one pull request.
Fix the last CodeRabbit comments.
Wait for CI.
Merge, then watch until GitHub reports the merge.
Do not run `/age` or `/affinage`; this skill is the short path for a PR that is already reviewed.

## Inputs

```text
/land [<pr>] [--full-review] [--no-merge] [--rounds <n>] [--include-outdated]
```

- `<pr>` — a PR number, `PR#<n>`, or a PR URL. Default: the PR of the current branch.
- `--full-review` — request `@coderabbitai full review` instead of `@coderabbitai review`.
- `--no-merge` — stop after CI is green. Report the merge command instead of running it.
- `--rounds <n>` — maximum fix → push → re-review rounds. Default 3.
- `--include-outdated` — also triage threads GitHub marks outdated. Default: skip them.

Exact `gh` commands live in `references/gh-recipes.md`. Read it before step 2.

## Flow

1. **Resolve the PR.** Run `gh pr view` with the JSON fields in the recipes.
   Halt when the state is `MERGED` or `CLOSED`.
   Check out the head branch when it is not the current branch.
   Halt when the working tree has changes this skill did not make.
2. **Read CodeRabbit state.** Fetch the bot's top-level comments and the head-SHA check runs.
   Classify the newest bot signal as one of:
   - `rate-limited` — the newest bot comment mentions a rate limit, or a check named `Review rate limited` exists.
   - `paused` — the newest bot comment says reviews are paused, skipped, or auto-paused.
   - `reviewed` — a bot review exists for the head SHA.
   - `pending` — the head SHA is newer than the last bot review and no signal above applies.
3. **Request a review when needed.** For `rate-limited`: parse a wait time from the comment; when none exists, use 5 minutes.
   Wait that long (cap 60 minutes) with the host wait primitive or a bounded `sleep` loop.
   For `rate-limited` or `paused`: post `@coderabbitai review` (or `full review` with `--full-review`).
   For `pending`: post nothing; CodeRabbit reviews pushes on its own.
   Then wait for a bot review or a bot summary comment newer than the request (timeout 20 minutes).
   A second rate-limit comment counts as one round.
4. **Collect open threads.** Use the GraphQL `reviewThreads` query.
   Keep threads where `isResolved` is false and the first comment author is `coderabbitai`.
   Skip `isOutdated` threads unless `--include-outdated` is set.
   When no thread remains and the newest bot review says `Actionable comments posted: 0`, go to step 7.
5. **Triage and fix.** Classify each thread:
   - **accept** — a contained fix inside the PR's scope. Apply it.
   - **reject** — wrong, unsupported, or out of scope. Draft a one-sentence reason.
   - **needs-human** — a fix that changes the PR's design or touches files outside its scope. Stop and ask.
   Apply accepted fixes inline when they touch at most 5 sites in at most 3 files.
   Otherwise dispatch `coder` with `Done means` and `Scope fence` lines.
6. **Gate, commit, push.** Run the project's check gate (`just check` when the justfile defines it; else the project's documented test command).
   Commit with a `fix:` subject that names the review.
   Push with `/plate` when the skill exists; else `git push`.
   Reply on every triaged thread (`Fixed in <sha> — …` or `Not applied — <reason>`), then resolve accepted threads with `resolveReviewThread`.
   Sign each reply `agent on behalf of <handle>`.
7. **Wait for CI.** Run `gh pr checks <n> --watch --fail-fast`.
   On failure, read the failed job log.
   Fix a contained failure (counts as one round) and return to step 6.
   Halt on a failure outside the PR's scope.
8. **Wait for the re-review.** After a push, repeat step 2 and step 3.
   When new unresolved bot threads exist and rounds remain, return to step 4.
   When rounds are exhausted, halt with the open thread list.
9. **Merge and watch.** Skip this step with `--no-merge`.
   Read the repo's allowed merge methods and prefer squash.
   Run `gh pr merge <n> --squash --delete-branch`; add `--auto` when the branch is protected or a merge queue exists.
   Poll `gh pr view --json state,mergedAt` every 30 seconds until `MERGED` (timeout 30 minutes).
   Halt on `mergeStateStatus: DIRTY` and route conflicts to `/melt`.
   Halt on `BLOCKED` and name the missing requirement.
10. **Report.** Use the output block below.

## Output

```markdown
status: ok | halt: <reason>
next: done | melt | affinage
artifact: <PR url>
<one line: rounds used, threads fixed / rejected / open, CI result, merge state>

| Thread | File | Decision | Reply |
|---|---|---|---|
```

## Rules

- Fix only what a CodeRabbit thread asks for; every changed line traces to a thread or a CI failure.
- Never post a reply without a fix or a reason.
- Never resolve a rejected thread; the reason stays visible.
- Never force-push.
- Never merge with `--admin`.
- Treat `Review rate limited` as a passing check that proves nothing; the bot comment is the signal.
- Count every wait against `--rounds`; the skill ends, it does not spin.

## Gotchas

- `request_changes_workflow: false` (the default) means CodeRabbit never blocks merge by review state; a green `reviewDecision` does not prove the bot reviewed the head SHA.
- `@coderabbitai resolve` resolves every bot thread at once, rejected ones included. Use per-thread `resolveReviewThread` instead.
- CodeRabbit auto-pauses after 5 reviewed commits by default (`auto_pause_after_reviewed_commits`); a long PR needs an explicit `@coderabbitai review` even without a rate limit.
- `gh pr checks --watch` exits non-zero on any failed check, including a stale one from an old push; confirm the check ran on the head SHA before you fix.

## References

- `references/gh-recipes.md` — read at step 2; every `gh` and GraphQL command with its JSON fields.
