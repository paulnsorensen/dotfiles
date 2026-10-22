---
name: t3-land
description: >
  Run the move-my-cheese landing workflow phases with T3 delegated subagents
  in a T3 thread. Outside T3, use the Workflow tool with move-my-cheese.
model: opus
effort: high
---

# t3-land

This wrapper runs the move-my-cheese landing workflow as a T3 parent thread. The workflow source stays the reference.

Source: `~/.claude/workflows/move-my-cheese.js` (deployed copy of `claude/workflows/move-my-cheese.js`). Follow its phase order, prompts, and stop rules. The design rationale is in `.hallouminate/wiki/architecture/move-my-cheese-workflow.md`.

Run the Boot in `~/.claude/skills/t3-core/SKILL.md`.

Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. For prose skills that name a preferred type in their `## Agent resolution` table, pass that type.

## Overrides

- **Integrate and restack.** The parent runs git by SHA itself. Dispatch no child for these steps.
- **Chained phases.** Use `t3-age` for Age and re-age, `t3-cure` for Cure, and `t3-affinage` for Affinage.
- **Exception list.** A dispatch with no agent type uses these roles: formatter repair uses `formatter`; recon uses `recon`; status, merge, and stamp use `runner`.

## Gates

Use the cheese-factory gates through `t3-run gate <name>`. Do not use the copy of UNSAFE_CHECKS in the workflow source.

- `merge-curds` for a coupled-curd merge.
- `check-safe` for each check command that you extract.
- `route-findings` to send age findings to the owning curds.
- `ranges` for continuation source ranges.
- `sha` for every writer head.

Integrate each builder child by branch and full head SHA through `t3-run gate sha`.
