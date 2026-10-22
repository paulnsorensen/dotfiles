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

## Source

Read the source for the chosen mode in full. Follow its phase order, prompts, and stop rules.

- Grounded research: `~/.claude/workflows/brie-ground.js` (deployed copy of `claude/workflows/brie-ground.js`).
- Issue triage: `~/.claude/skills/rennet/SKILL.md`.

If the source is missing, stop with an error that names the path. Launch no child.

## Overrides

Read `~/.claude/skills/t3-core/SKILL.md`, `references/dispatch-protocol.md`, and `references/result-rules.md` in that directory before the first dispatch.

1. Run the parent check in the dispatch protocol first.
2. Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`.
3. Get each target from `t3-run role <role>`. Never write a model id.

## Phase to role

| Phase | Role |
|---|---|
| brie-ground researchers | `researcher` |
| brie-ground verifiers | `verifier` |
| rennet per-issue triage | `explorer` |

## Gates

Run each deterministic step through `bin/t3-run gate <name>` (`t3-run gate <name>`). The research modes use `check-safe` for each check command that you extract.

## Nesting

A nested phase uses the matching `t3-*` wrapper. Follow `~/.claude/skills/t3-core/references/dispatch-protocol.md` § Nesting for depth.
