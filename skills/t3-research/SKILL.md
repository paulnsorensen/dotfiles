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

Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. For prose skills that name a preferred type in their `## Agent resolution` table, pass that type.

## Overrides

- **Exception list.** A dispatch with no agent type uses these roles: rennet per-issue triage uses `explorer`.
- **Gates.** Run `t3-run gate check-safe` for each check command that you extract.
