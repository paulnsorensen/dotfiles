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
<!-- move-my-cheese:aged sha=<head-sha> patch=<patch-id> dirty=<0|1> -->
```

Chosen over git notes (local unless explicitly pushed, invisible on GitHub)
and a durable-corpus artifact (machine-local) because the marker must survive
across machines and disposable worktrees, and gives visible provenance on the
PR itself.

## Why the marker records BOTH sha and patch-id

The Age phase decides its scope in four steps, in order:

1. Marker `dirty=1` (the previous age left unresolved medium+ findings) →
   **full** `/age` — skip/incremental would hide those findings, and triage
   never short-circuits a dirty head as fresh.
2. `git diff origin/<base>...HEAD | git patch-id --stable` equals the marker
   `patch=` → the reviewable content is unchanged (e.g. a `/plate` restack
   rewrote history but changed nothing) → **skip `/age` entirely**.
3. Marker `sha=` is an ancestor of HEAD → **incremental** `/age <sha>..HEAD`.
4. Otherwise → **full** `/age origin/<base>...HEAD`.

The sha alone would force a full re-age after every restack (rewritten
history breaks the ancestor check); the patch-id alone can't scope an
incremental review. Together: restack-only → skip; new commits on unrewritten
history → incremental; rewrite with content changes → full.

## Threshold-gated dimension fan-out (ADR-007)

Before dispatching the single-reviewer Age agent, the script computes

```
fanOut = (!aged_sha || aged_dirty) && (changed_files > 15 || additions + deletions > 800)
```

using diff stats recon now gathers via `gh pr view --json changedFiles,additions,deletions`.
When it holds, the Age runs as `workflow('age-fanout', {worktree_path, range,
slug: 'pr-<n>'})` — one reviewer per /age dimension, semantics read at runtime
from the deployed skill files — instead of one inline reviewer. Two deliberate
bounds:

- **Only full-review candidates fan out.** A clean marker means the scope will
  be skip or incremental (small delta), where fan-out cost isn't justified; the
  marker/patch-id logic above stays entirely on the single-reviewer path.
- **The gate lives in JS, the scope decision in the agent.** The fan-out
  decision needs stats *before* dispatch; the skip/incremental/full decision
  needs `git patch-id` and stays agent-side. When both could apply, dirty=1 or
  no-marker guarantees the agent would have chosen full anyway.

The child call is wrapped in try/catch: if `age-fanout` is unavailable, the PR
falls back to the single-reviewer path rather than failing. A prep agent
creates the worktree only when the Rescue phase didn't already leave one.
Rationale and the child workflow's design: [[adr/cheese-factory-workflow]]
(ADR-007).

Related: [[architecture/agents-dir]] (deploy path: `claude/workflows/` →
`~/.claude/workflows/` via `dots sync`), tests in
`tests/workflows/move-my-cheese.test.mjs` (offline harness, `just smoke`).
