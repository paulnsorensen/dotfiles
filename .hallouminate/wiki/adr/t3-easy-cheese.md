# ADRs — t3-easy-cheese

Decisions behind the T3 versions of easy-cheese processes. These skills run every subagent as a T3 delegated task. Spec: durable corpus `specs/t3-easy-cheese.md` (`~/.local/share/cheese/paulnsorensen-dotfiles/`), Mold session 2026-10-22. Related: [[architecture/t3-code-launch]], [[adr/cheese-factory-workflow]], [[adr/subagent-routing-overhaul]], [[architecture/omp-agent-model-effort]].

## Role map (user decision, 2026-10-22)

The parent is the T3 thread on `claude-opus-5-5`. Opus also does primary review, planning, and taste tests. Codex `gpt-6-astra` at `high` is the advisor (plan gate, done gate, judge advise mode). Codex `gpt-6.1-sol` at `high` is the second reviewer. `claude-sonnet-5-5` is the coder and worker. `claude-haiku-5-5` fills cheap tool roles, and codex `gpt-6-luna` at `medium` or higher fills cheap text roles. The map applies to `t3-*` skills only; `agents/registry.yaml` stays unchanged. Single source: `skills/t3-core/role-map.json`.

## ADR-1: Separate t3-* skills in dotfiles [accepted]

- Decision: ten `t3-*` skills live in dotfiles `skills/`, not a T3 transport inside easy-cheese `agent-resolution.md`.
- Alternatives: an easy-cheese T3 transport (no copies, needs an easy-cheese change); a Workflow bridge (subagent call untested at the time, two dispatch layers).
- Consequence: drift risk, which ADR-3 contains.

## ADR-2: Async children with a run ledger [accepted]

- Context: two `mode: wait` delegate_task calls in one tool batch ran one after the other (probe, 2026-10-22).
- Decision: launch children with `mode: async`, record each `taskId` in `.cheese/t3/<run>.json` through `bin/t3-run ledger`, end the turn, and advance when a phase barrier completes.
- Consequence: real parallelism and a resumable run. Whether a stored `taskId` survives a T3 service restart is unverified.

## ADR-3: Thin wrappers read the real skill at runtime [accepted]

- Decision: each wrapper reads the deployed easy-cheese `SKILL.md` or workflow source and overrides only dispatch and role targets (the cheese-factory ADR-007 pointer pattern). A missing pointer stops the wrapper before any child launch.

## ADR-4: Every subagent is a T3 child, nested at every depth [accepted]

- Decision: cheap roles also run as T3 children. A child that runs a dispatching phase uses the matching `t3-*` wrapper, so grandchildren follow the role map. Depth caps at 2 below the parent.
- Evidence: a Haiku child started a grandchild; a Codex Sol child has `mcp__t3_code__delegate_task`.
- Consequence: each micro-task pays a full session prompt. `gpt-6-luna` at `low` returned fabricated empty JSON without a tool call, so cheap results are schema-checked with one Haiku retry.

## ADR-5: Gate code shared through a vm-loaded plain-script block [accepted]

- Context: workflow scripts cannot import (ADR-014 of cheese-factory); `tests/workflows/harness.mjs` loads them through `node:vm`.
- Decision: the strict cheese-factory gate helpers move into `claude/workflow-prelude/gates.js`. `sync.mjs` pastes it into `cheese-factory.js`, and `bin/t3-run gate` loads it and `prelude.js` through `node:vm`. `t3-land` uses these gates, not the diverged `move-my-cheese.js` copy.

## Gotchas

- `delegate_task` with `isolation: worktree` starts from the parent HEAD and names its own branch (`t3/<slug>`). Uncommitted parent edits do not copy.
- A Codex child routes file reads through tilth, not Bash.

_Source: Mold session 2026-10-22, probes S-1..S-9 · Updated: 2026-10-22_
