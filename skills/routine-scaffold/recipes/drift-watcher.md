# Recipe: drift-watcher

The reference pattern — watch external upstreams whose docs/releases govern your
config, detect drift, and triage each into a PR or an issue. Generalizes the live
`agents/doc-drift/` watcher.

- **Shape:** scan-and-triage watcher (the full triad).
- **Suggested trigger:** `cron` — e.g. `0 8 * * 1,4` (Mon + Thu 08:00 UTC).
- **Connectors:** Tavily (release notes / changelogs) + Context7 (config / API
  docs).

## Artifacts to scaffold

1. `agents/<name>/sources.yaml` — the watched sources: each with an `id`, a
   `signal` (how to resolve current state, e.g. `npm view` / `gh release`), the
   files it `governs`, and a `reconciled` marker (last version a human folded in).
2. `bin/<name>-scan` — resolves each source's current version, compares to
   `reconciled`, emits JSON per source (`{id, current, drifted, status}`).
   Deterministic; fails loud on an unknown signal type. Ship bats tests.
3. `agents/<name>/routine.md` — the orchestrator prompt below.

## Objective

Detect drift between watched upstreams and our config; triage each drift and open
exactly one artifact per drifted item.

## Prompt skeleton

```text
You are the orchestrator for <repo>'s drift routine. Detect drift between
watched upstreams and our config, then triage and act on each drift.

1. Ensure the tracking label exists (idempotent): gh label create <name> ... || true
2. Run bin/<name>-scan; parse its JSON. Take items where .drifted == true.
   If none, exit quietly — no output, no artifacts.
3. Dispatch one subagent per drifted item (parallel; file-disjoint). Each:
   - Dedup: if an open PR/issue or branch <name>/<id>-<current> covers it, report `dup`.
   - Read the change via Tavily (release notes) + Context7 (docs); read the
     governs files directly.
   - Classify: no-op | small | large/idea.
   - Act: no-op/small -> PR (bump the reconciled marker; small also edits governs);
     large/idea -> GH issue (no bump). Never a direct push to a default branch.
4. Print a one-line summary per item.

Invariants: never auto-merge; reconciled advances only inside a PR; one artifact
per item; subagents are file-disjoint.
```

## Review checklist

- Scanner has tests and fails loud on unknown signals.
- `reconciled` bumped only inside a PR.
- Dedup checks open PRs/issues and the branch.
- Never-auto-merge invariant present.
