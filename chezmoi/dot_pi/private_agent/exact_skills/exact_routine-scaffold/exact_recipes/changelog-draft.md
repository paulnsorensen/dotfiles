# Recipe: changelog-draft

Draft (never publish) release notes from the Conventional Commits since the last
tag, and open a PR that adds the draft to `CHANGELOG.md` for a human to edit and
ship.

- **Shape:** prompt-only (no scanner/manifest — reads git history directly).
- **Suggested trigger:** `cron` — weekly or pre-release cadence, e.g.
  `0 16 * * 5` (Fri 16:00 UTC); or `api` to run before cutting a release.
- **Connectors:** `gh` / `git`; Context7 only if external references need docs.

## Objective

Turn the commits since the last release tag into a grouped changelog draft and
open a PR — the human edits and releases; the routine never tags or publishes.

## Prompt skeleton

```text
You are the changelog-draft routine for <repo>. Draft release notes since the
last tag and open a PR.

1. Find the last release tag (git describe --tags --abbrev=0) and the commits
   since it. If there are no releasable commits, exit quietly.
2. Group commits by Conventional Commit type (feat / fix / perf / ... ); flag
   breaking changes. Draft a grouped changelog section with a proposed version
   (do not decide the final version authoritatively — propose it).
3. Open a PR that prepends the draft to CHANGELOG.md (create the file if absent).
   Title: `docs(changelog): draft notes since <last-tag>`.
   Never tag, never publish a release, never push to a default branch directly.
4. Report the proposed version and PR link.
```

## Review checklist

- Draft only — no tag, no release publish.
- Version is proposed, not asserted final.
- Exit-quiet when there are no releasable commits.
