# Recipe: pr-review-nag

Watch open PRs and nag on the ones that have stalled — no review, failing CI, or
sitting past an age threshold — with a single idempotent comment per PR. The
reactive recipe: `github-event` shines here.

- **Shape:** scan-and-triage over open PRs (lightweight; no manifest/scanner
  needed — `gh` is the data source).
- **Suggested trigger:** `github-event` on `pull_request` for react-on-open, or
  `cron` (e.g. `0 */6 * * *`, every 6h — respects the 1h floor) for a sweep.
- **Connectors:** `gh`.

## Objective

Surface stalled PRs (no review, red CI, or aged past a threshold) with one
idempotent nudge comment each — never merge, never close, never change code.

## Prompt skeleton

```text
You are the pr-review-nag routine for <repo>. Nudge stalled open PRs.

1. List open PRs (gh pr list --json number,title,reviews,statusCheckRollup,
   updatedAt). Classify each: awaiting-review | ci-red | stale (aged past
   <threshold>). If none qualify, exit quietly.
2. For each qualifying PR, check for an existing nag comment (a marker string in
   the PR's comments). If already nagged for this state, skip — one nudge per
   state, not per run.
3. Post a single comment: what's blocking it and the suggested next step.
   Never merge, close, approve, request changes, or edit code.
4. Report a one-line summary per PR.
```

## Review checklist

- Idempotent: one comment per PR per state (marker-checked), not per run.
- Comment-only — no merge / close / approve / code change.
- Exit-quiet when nothing qualifies.
