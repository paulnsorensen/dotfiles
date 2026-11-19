---
name: architecture-review
description: Creates an offline, revision-pinned architecture map for a repository or diff. Use when a user asks to review code architecture in context, explore changed subsystems, or explain a public boundary with cited source.
model: sonnet
effort: medium
---

# Architecture review

Generate one static local viewer. The browser never starts workers or reads the checkout.

## Run

Use `python3 "$(dirname "$SKILL_PATH")/scripts/review.py" REPO [--rev REV | --base BASE --head HEAD] [--focus ID | --explain ID] [--out DIR] [--cache DIR] [--model NAME] [--replies FILE]`.
Here, `SKILL_PATH` is this installed `SKILL.md` path. Keep the package together when copying it.
The script needs Python 3.12 or later and Git. TypeScript and Rust evidence needs `ast-grep` on `PATH`; other evidence remains available without it.
The script reads committed Git objects and does not execute repository code.
The default review uses `HEAD`. A diff compares the specified trees directly.
`--focus` opens one group. `--explain` requests analysis for one named group in a diff.
Open the `viewer` path from the JSON result in a local browser.
Do not serve it or upload the embedded source.

Select a subsystem, then a symbol, to open its code diagram.
Select a neighboring symbol to move the diagram there.
Select an arrow to inspect its source line at the displayed revision.
Use Back to restore the previous diagram.
Inspect removed calls at base; they are not head dependencies.
These arrows show resolved references, not observed execution.

The default cache persists by repository path under `${XDG_CACHE_HOME:-~/.cache}/architecture-review/` on Linux.
On macOS, it uses `~/Library/Caches/architecture-review/` unless `XDG_CACHE_HOME` is set.
The script creates a private per-repository cache directory with mode 0700.
A repeat invocation reuses accepted analysis. A different repository uses a different cache key.
The default output is a new private temporary directory. Save the returned viewer path before the session ends.
Set `--out` to reuse an owned private output directory. Set `--cache` to override the persistent cache.
The script rejects non-private existing output or cache directories, symlink paths, and unmanaged nonempty output directories.
It never changes an existing directory's permissions.

## Worker boundary

The host may supply `--model NAME` only after it confirms an available lower-tier, read-only worker on the authorized host.
Announce that model and these limits before dispatch: at most two concurrent workers, four jobs per invocation, 120 seconds per job, and twelve cited claims per reply.
Do not switch providers or send private evidence to another service.
Without that capability, omit `--model`. A focused review reports `worker_status: unavailable` and uses the static viewer.
A repository overview reports `repository`. A diff without changed focus reports `no-change`.
The script never dispatches a worker or treats a scheduled task as completed analysis.

For scheduled tasks, read [references/worker.md](references/worker.md) before dispatch.
Pass one task JSON path to each worker. Do not pass the full viewer, full evidence document, or other task files.
Use the host's read-only lower-tier agent facility. Store replies as one JSON array and rerun the same command with `--replies FILE`.
Reuse the same output, cache, model, revisions, and focus. Ingestion uses the original task IDs; it does not schedule replacement tasks.
A warm accepted result starts no workers. A missing or late reply remains missing analysis.

## Discipline

Do not call a scheduled task a completed assessment.
If the model is unavailable, a task expires, or a reply fails validation, keep the static view and report the gap.
Browsing, search, expansion, source links, and Back spend no model budget.

## Example

`python3 skills/architecture-review/scripts/review.py . --base cb92ab00 --head fa73ab4e --out /tmp/review-example --cache /tmp/review-cache`
The JSON result names `index.html`. Open it offline to inspect the change in its subsystem context.
