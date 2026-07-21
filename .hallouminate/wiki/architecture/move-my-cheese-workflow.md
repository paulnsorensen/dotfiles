# move-my-cheese workflow — incremental PR-age marker

`claude/workflows/move-my-cheese.js` is the modern descendant of the archived
`archive/claude-commands/{move-my-cheese,cheese-convoy}.md` slash commands:
cheese-convoy's parallel per-PR dispatch plus move-my-cheese's rescue flow.
Convoy's combine/consolidate phases were deliberately dropped — Workflow runs
are background and cannot pause for the mid-run approval gate those phases
required. Restacking is delegated to `/plate`, conflict melting to `/melt`,
review to `/age`, fixes to `/cure`; the workflow only orchestrates.

## Why a PR-comment marker (not git notes or a local artifact)

Each aged PR carries one upserted comment:

```
<!-- move-my-cheese:aged sha=<head-sha> patch=<patch-id> -->
```

Chosen over git notes (local unless explicitly pushed, invisible on GitHub)
and a durable-corpus artifact (machine-local) because the marker must survive
across machines and disposable worktrees, and gives visible provenance on the
PR itself.

## Why the marker records BOTH sha and patch-id

The Age phase decides its scope in three steps, in order:

1. `git diff origin/<base>...HEAD | git patch-id --stable` equals the marker
   `patch=` → the reviewable content is unchanged (e.g. a `/plate` restack
   rewrote history but changed nothing) → **skip `/age` entirely**.
2. Marker `sha=` is an ancestor of HEAD → **incremental** `/age <sha>..HEAD`.
3. Otherwise → **full** `/age origin/<base>...HEAD`.

The sha alone would force a full re-age after every restack (rewritten
history breaks the ancestor check); the patch-id alone can't scope an
incremental review. Together: restack-only → skip; new commits on unrewritten
history → incremental; rewrite with content changes → full.

Related: [[architecture/agents-dir]] (deploy path: `claude/workflows/` →
`~/.claude/workflows/` via `dots sync`), tests in
`tests/workflows/move-my-cheese.test.mjs` (offline harness, `just smoke`).
