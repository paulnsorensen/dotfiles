# Recipe: flaky-test-triage

Watch recent CI runs for tests that fail intermittently, cluster them by test,
and open an issue per flaky test (never a silent skip or auto-quarantine).

- **Shape:** scan-and-triage watcher over CI history.
- **Suggested trigger:** `cron` — daily, e.g. `0 7 * * *` (07:00 UTC), or
  `github-event` on `workflow_run` completion for reactive triage.
- **Connectors:** `gh` (CI runs / logs); Context7 for test-framework docs.

## Objective

Identify tests that pass and fail without a code change (flaky), and file one
tracked issue per flaky test with the failure evidence — never quarantine or skip
a test automatically.

## Prompt skeleton

```text
You are the flaky-test-triage routine for <repo>. Find intermittently failing
tests and file a tracked issue per flaky test.

1. Ensure label `flaky-test` exists (idempotent).
2. Pull recent CI runs (gh run list / gh run view --log). Identify tests that
   both passed and failed across runs on the same commit range (flaky signal).
   If none, exit quietly.
3. Cluster failures by test id. Dedup against open `flaky-test` issues.
4. For each new flaky test, open an issue: the test id, the failing runs, the
   error signature, and how often it flaked. Do NOT edit tests, skip, or
   quarantine — a human decides the fix.
5. Print a one-line summary per test.
```

## Review checklist

- Flaky classification rests on observed pass+fail on the same code, not a guess.
- Issues only — no test edits, skips, or quarantines.
- Dedup against existing issues; exit-quiet on clean.
