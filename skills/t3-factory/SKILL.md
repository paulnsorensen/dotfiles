---
name: t3-factory
description: >
  Run the cheese-factory workflow phases with T3 delegated subagents in a T3
  thread. Outside T3, use the Workflow tool with cheese-factory instead.
model: opus
effort: high
---

# t3-factory

This wrapper runs the cheese-factory workflow as a T3 parent thread. The workflow source stays the reference.

Source: `~/.claude/workflows/cheese-factory.js` (deployed copy of `claude/workflows/cheese-factory.js`). Follow its phase order, prompts, and stop rules. The design rationale is in `.hallouminate/wiki/adr/cheese-factory-workflow.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

## Overrides

- **Integrate and re-merge.** The parent runs git by SHA itself. Dispatch no child for these steps.
- **Barrier age.** Use the `t3-age` wrapper.
- **Plate.** The parent runs `/plate`.

## Gates

Run each deterministic step through `t3-run gate <name>`:

- `merge-curds` for a coupled-curd merge.
- `check-safe` for each check command that you extract.
- `route-findings` to send age findings to the owning curds.
- `ranges` for continuation source ranges.
- `sha` for every writer head.

Integrate each writer child by branch and full head SHA through `t3-run gate sha`.
