---
name: t3-research
description: >
  Run grounded research (brie-ground) or issue triage (rennet) with T3
  delegated subagents in a T3 thread. Outside T3, use the Workflow tool or
  `/rennet`.
---

# t3-research

This wrapper runs two modes as a T3 parent thread: grounded research and issue triage. The sources stay the reference.

## Source

Read the source for the chosen mode in full. Follow its phase order, prompts, and stop rules.

- Grounded research: `~/.claude/workflows/brie-ground.js` (deployed copy of `claude/workflows/brie-ground.js`).
- Issue triage: `~/.claude/skills/rennet/SKILL.md`.

If the source is missing, stop with an error that names the path. Launch no child.

## Overrides

Apply the T3 override block in `~/.claude/skills/t3-core/SKILL.md`:

- Run the parent check first.
- In each phase, launch async, record each child in the ledger, and wait at the barrier.
- Start each child prompt with `T3-Depth: <n>`.
- Take each role target only from `t3-run role <role>`.

Read `~/.claude/skills/t3-core/references/result-rules.md` before you accept a child result.

## Phase to role

| Phase | Role |
|---|---|
| brie-ground researchers | `researcher` |
| brie-ground verifiers | `verifier` |
| rennet per-issue triage | `explorer` |

## Gates

Run each deterministic step through `bin/t3-run gate <name>` (`t3-run gate <name>`). The research modes use `check-safe` for each check command that you extract.

## Nesting

A nested phase uses the matching `t3-*` wrapper. Depth caps at 2. A depth 2 child runs inline.
