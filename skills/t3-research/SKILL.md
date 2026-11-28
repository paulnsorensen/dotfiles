---
name: t3-research
description: >
  Run grounded research (brie-ground) or issue triage (rennet) with T3
  delegated subagents in a T3 thread. Outside T3, use the Workflow tool or
  `/rennet`.
model: opus
effort: high
---

# t3-research

This wrapper runs two modes as a T3 parent thread: grounded research and issue triage. The sources stay the reference.

Choose the source by mode. Follow its phase order, prompts, and stop rules.

- Grounded research: `~/.claude/workflows/brie-ground.js` (deployed copy of `claude/workflows/brie-ground.js`).
- Issue triage: `~/.claude/skills/rennet/SKILL.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

## Overrides

- **Exception list.** A dispatch with no agent type uses these roles: rennet per-issue triage uses `explorer`.
- **Grounded research phases.** These brie-ground phases override the agent type. Each retry uses the same role as its phase.
  - Verify (`brie-ground.js:697`) uses `verifier`.
  - Plan (`brie-ground.js:791`) uses `planner`.
  - Synthesize (`brie-ground.js:840`) uses `researcher`.
  - Prototype (`brie-ground.js:851`) uses `coder`.
- **Rennet mode.** Rennet keeps its role mapping.
- **Gates.** Run `t3-run gate check-safe` for each check command that you extract.
