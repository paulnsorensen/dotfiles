# Recipe: repo-brief

Produce a periodic digest of what changed in the repo — merged PRs, new issues,
notable diffs, dependency moves — and open an issue (or update a pinned tracking
issue) with the brief. Read-only against code; the only artifact is the brief.

- **Shape:** prompt-only (reads git/gh history; no scanner/manifest).
- **Suggested trigger:** `cron` — weekly, e.g. `0 15 * * 1` (Mon 15:00 UTC).
- **Connectors:** `gh` / `git`; Tavily/Context7 only if the brief cites external
  context.

## Objective

Summarize the repo's recent activity into a readable brief and post it as an
issue, so the maintainer gets a standing digest without auto-changing anything.

## Prompt skeleton

```text
You are the repo-brief routine for <repo>. Produce a weekly activity digest.

1. Ensure label `repo-brief` exists (idempotent).
2. Collect the last window's activity: merged PRs, opened/closed issues, notable
   commits, dependency changes (gh pr list --state merged, gh issue list, git
   log). If nothing meaningful happened, exit quietly.
3. Write a concise brief: what shipped, what's open and stalling, notable diffs,
   anything that needs attention. Evidence-linked (PR/issue/commit refs).
4. Post it as a new issue, or update the pinned `repo-brief` tracking issue.
   Never change code, never open a PR, never auto-merge anything.
5. Report the issue link.
```

## Review checklist

- Read-only against code — the brief is the only artifact.
- Every claim links to a PR/issue/commit (evidence, not inference).
- Exit-quiet on a dead week.
