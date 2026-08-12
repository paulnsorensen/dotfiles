# Recipe: stale-docs

Scan the repo's docs for staleness — references to renamed/removed files,
commands, or symbols that no longer exist — and open a PR (small fixes) or issue
(judgment calls) per cluster.

- **Shape:** scan-and-triage watcher (lightweight — a scanner helps but the
  manifest can be a glob set).
- **Suggested trigger:** `cron` — weekly, e.g. `0 9 * * 1` (Mon 09:00 UTC).
- **Connectors:** Context7 (for external tool/API references) + repo file reads.

## Objective

Find docs that reference things that no longer exist (moved files, removed
flags/commands, renamed symbols) and reconcile each with a PR or flag it with an
issue.

## Prompt skeleton

```text
You are the stale-docs routine for <repo>. Find docs whose references have gone
stale and reconcile them.

1. Ensure label `stale-docs` exists (idempotent).
2. Scan docs (README, docs/, wiki, *.md) for references to repo paths, commands,
   or symbols. For each referenced path/command/symbol, verify it still exists
   (git ls-files, --help output, code search). Collect broken references.
   If none, exit quietly.
3. Group broken references by doc. Dedup against open PRs/issues.
4. Act per group:
   - Mechanical fix (path/name update) -> PR.
   - Ambiguous (needs a human's intent) -> issue with the evidence.
   Never a direct push to a default branch; never auto-merge.
5. Print a one-line summary per doc.
```

## Review checklist

- Verification is evidence-based (the reference actually resolves or not), not a
  guess.
- Ambiguous rewrites become issues, not silent edits.
- Dedup present; exit-quiet on clean.
