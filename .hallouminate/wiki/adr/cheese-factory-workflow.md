# ADRs — cheese-factory-workflow

Decisions behind replacing `claude/workflows/curd-flock.js` with the spec-driven `/cheese-factory` workflow. Spec: durable corpus `specs/cheese-factory-workflow.md` (`~/.local/share/cheese/paulnsorensen-dotfiles/`).

## ADR-001: Real-skill phase agents over prompt-modeled phases  [status: accepted]

- **Context:** curd-flock approximated the cook/review phases with inline prompts + JSON schemas. The redesign mirrors the easy-cheese pipeline; prompt copies drift as the skills evolve.
- **Decision:** Each workflow phase agent invokes the real skill (`/cook <spec> --auto`, `/press`, `/age`, `/cure`, `/plate`) carrying ultracook's no-chain-forward directive; handoff slugs land in the curd worktree's `.cheese/`.
- **Alternatives:** Prompt-modeled (self-contained, no skill dependency, drifts); hybrid (mixed fidelity). Rejected for drift and inconsistency.
- **Consequences:** Exact easy-cheese behavior and durable handoffs; new dependency on Skill-tool availability inside workflow agents — gated by a pre-implementation smoke check, with prompt-modeled as the flagged fallback.

## ADR-002: Barrier plate overrides the never-push contract  [status: accepted]

- **Context:** curd-flock never pushed — it handed back branches. The user explicitly added plate/stack (opus) to the chain.
- **Decision:** One opus plate agent runs once after all curd chains: stacks clean `curd/<slug>` branches into a stacked-PR chain (ordinary PR in single-pass). Dirty curds (re-age still medium+) are excluded and reported. Plate never merges.
- **Alternatives:** Per-curd independent PRs (no stacking/ordering); prepare-don't-push (kept the old contract, user declined).
- **Consequences:** Unattended pushes/PRs from a workflow run; bounded by never-merge and dirty-curd exclusion.

## ADR-003: Reuse `mold.pyz curd-count` via agent-side Bash  [status: accepted]

- **Context:** Workflow scripts have no filesystem/Bash access; the fan-out decision needs curd-count's goal-counting.
- **Decision:** A cheap Resolve agent shells out to `mold.pyz curd-count` (and `artifact-path`) and returns structured JSON to the script.
- **Alternatives:** Reimplement goal-counting in JS inside the workflow (duplicate logic, drifts from mold's PARALLEL_THRESHOLD).
- **Consequences:** One canonical threshold shared with /mold//ultracook; adds a python3 + skill-bundle dependency for the Resolve agent.

## ADR-004: Per-curd mini-specs anchor the real skills  [status: accepted]

- **Context:** Real skills take a spec slug; N curds share one parent spec.
- **Decision:** The decomposer writes per-curd mini-specs (mold mini-spec schema) at `specs/<parent>--<curd>.md` via the resolver; single-pass mode uses the parent spec directly.
- **Alternatives:** Inline curd briefs in prompts (no durable anchor; press/age/cure would have nothing to read).
- **Consequences:** Whole chain per curd reads/writes against a durable spec; corpus gains derived spec files per run.

## ADR-005: File-overlapping curds merge instead of warn-and-proceed  [status: accepted]

- **Context:** curd-flock's overlap check was advisory (log a warning, fan out anyway) — a race window on shared files. ultracook folds shared-file curds back to linear.
- **Decision:** JS merges any file-overlapping curds into one curd (one worktree, combined brief); if merging leaves one curd, run single-pass.
- **Alternatives:** Warn-only (curd-flock behavior); abort the run on overlap.
- **Consequences:** Fan-out is always file-disjoint by construction; a heavily-coupled spec degrades gracefully to single-pass.
