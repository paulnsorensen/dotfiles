# Domain model — dotfiles

Cumulative ubiquitous language for this repo's agent-orchestration domain. Merge, don't overwrite; context-specific terms only.

**Curd** — one file-disjoint unit of a decomposed spec, implemented on its own `curd/<slug>` branch in its own worktree.
_Avoid_: task, unit, slice
_Code_: skills/mold/references/curd-count.md:40-54 (`candidate_curds`)

**Single-pass** — cheese-factory's non-fan-out mode: one worktree running the full phase chain against the parent spec.
_Avoid_: linear mode
_Code_: NEW ENTITY (claude/workflows/cheese-factory.js mode)

**Taste-test** — the standalone post-cook reviewer gate (drift / readability / scope / production-path / wired-callers).
_Avoid_: quick review
_Code_: claude/workflows/cheese-factory.js:252-263 (`tastePrompt` lens set)

**Mini-spec** — per-curd spec written by the decomposer at `specs/<parent>--<curd>.md`, using mold's mini-spec schema.
_Avoid_: sub-spec
_Code_: skills/mold/SKILL.md § Agent-invoked mini-spec mode

**Plate barrier** — the single opus plate agent that runs once after all curd chains, stacking clean branches into a stacked-PR chain (never merges).
_Avoid_: publish step
_Code_: NEW ENTITY (claude/workflows/cheese-factory.js phase)

**No-chain-forward** — directive carried by every phase spawn overriding a skill's `--auto` chaining: write your handoff slug and stop.
_Code_: ~/.claude/skills/ultracook/SKILL.md:87-91
