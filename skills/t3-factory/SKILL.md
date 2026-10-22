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

## Source

Read `~/.claude/workflows/cheese-factory.js` in full (deployed copy of `claude/workflows/cheese-factory.js`). Follow its phase order, prompts, and stop rules.

If the file is missing, stop with an error that names the path. Launch no child.

The design rationale is in `.hallouminate/wiki/adr/cheese-factory-workflow.md`.

## Overrides

Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.

1. Run the parent check in the dispatch protocol first.
2. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.
3. Get each target from `t3-run role <role>`. Never write a model id.

## Phase to role

| Phase | Role |
|---|---|
| Resolve, Ground | `explorer` |
| Plan advise, done advise | `advisor` |
| Criteria | `planner` |
| Decompose | `planner` |
| Cook, continuation | `coder`, `continuation` |
| Press | `press` |
| Cure | `cure` |
| Taste | `taste-test` |
| Integrate, merge | `coder` (worktree; integrate by head SHA) |
| Barrier age | `t3-age` wrapper (reviewer lens groups and `second-reviewer`) |
| Verify judges | `verifier` |
| Plate | parent, with `/plate` |

## Gates

Run each deterministic step through `bin/t3-run gate <name>` (`t3-run gate <name>`):

- `merge-curds` for a coupled-curd merge.
- `check-safe` for each check command that you extract.
- `route-findings` to send age findings to the owning curds.
- `ranges` for continuation source ranges.
- `sha` for every writer head.

Integrate each writer child by branch and full head SHA through `t3-run gate sha`.

## Nesting

A nested phase uses the matching `t3-*` wrapper. Follow `~/.claude/skills/t3-core/references/dispatch-protocol.md` § Nesting for depth.
