---
name: t3-land
description: >
  Run the move-my-cheese landing workflow phases with T3 delegated subagents
  in a T3 thread. Outside T3, use the Workflow tool with move-my-cheese.
---

# t3-land

This wrapper runs the move-my-cheese landing workflow as a T3 parent thread. The workflow source stays the reference.

## Source

Read `~/.claude/workflows/move-my-cheese.js` in full (deployed copy of `claude/workflows/move-my-cheese.js`). Follow its phase order, prompts, and stop rules.

If the file is missing, stop with an error that names the path. Launch no child.

The design rationale is in `.hallouminate/wiki/architecture/move-my-cheese-workflow.md`.

## Overrides

Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.

1. Run the parent check in the dispatch protocol first.
2. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.
3. Get each target from `t3-run role <role>`. Never write a model id.

## Phase to role

| Phase | Role |
|---|---|
| Planners | `planner` |
| Advisor | `advisor` |
| Builders, integrate, restack | `coder` |
| Verify judge | `verifier` |
| Age, re-age | `t3-age` wrapper |
| Cure | `t3-cure` wrapper |
| Affinage | `t3-affinage` wrapper |
| Formatter repair | `formatter` |
| Recon, status | `recon`, `runner` |
| Merge, stamp | `runner` |

## Gates

Use the cheese-factory gates through `bin/t3-run gate <name>`. Do not use the copy of UNSAFE_CHECKS in the workflow source.

- `merge-curds` for a coupled-curd merge.
- `check-safe` for each check command that you extract.
- `route-findings` to send age findings to the owning curds.
- `ranges` for continuation source ranges.
- `sha` for every writer head.

Integrate each builder child by branch and full head SHA through `t3-run gate sha`.

## Nesting

A nested phase uses the matching `t3-*` wrapper. Follow `~/.claude/skills/t3-core/references/dispatch-protocol.md` § Nesting for depth.
