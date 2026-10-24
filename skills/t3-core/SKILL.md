---
name: t3-core
description: >
  Shared core for the `t3-*` skills: the T3 override block, the dispatch
  protocol, the result rules, and the role map. Not run directly. Each
  `t3-*` wrapper points here.
user-invocable: false
disable-model-invocation: true
---

# t3-core

This skill is the shared core for the `t3-*` wrapper skills. Do not run it directly.

## Boot

Every `t3-*` wrapper runs this Boot before its first dispatch.

1. Read the source that the wrapper names, in full. Follow it.
2. If the source is missing, stop with an error that names the path. Launch no child.
3. Read this file, `references/dispatch-protocol.md`, and `references/result-rules.md` in this directory.
4. At depth 0 (the prompt has no `T3-Depth` line), run the parent check in the dispatch protocol. At depth 1 or more, skip it.
5. Apply the T3 override block below.
6. Resolve each dispatch the source makes with `t3-run role --agent-type <type> [--tier <tier>] [--mode <mode>] --depth <n>`. When the source has an `## Agent resolution` table that names a preferred type, pass that type.

## T3 override block

A wrapper follows its real skill or workflow source. It applies only these two overrides.

1. **Dispatch.** Send every subagent through the T3 `delegate_task` tool. Follow [the dispatch protocol](references/dispatch-protocol.md). Do not use native host subagents.
2. **Targets.** Take each dispatch target only from `t3-run role`. The command prints `{role, providerInstanceId, model, options, isolation}`. Pass `--depth <n>` with the child's depth (the sender's depth + 1). Depth 3 or more exits before launch.

`bin/t3-run` is on PATH as `t3-run`; call it as `t3-run` from any repository.

Model ids live only in `role-map.json`. Do not write a model id or a bare alias in a wrapper or a reference. One exception: the parent check in `dispatch-protocol.md` names `claude-opus-5-5`.

## Role resolution

Every role lookup passes `--depth <child depth>`. The command refuses a lookup without it.

- **Tier.** Pass the `model:` value of the source dispatch. An unknown tier exits 2.
- **Mode.** Pass the judge prompt mode: `advise` or `verify`. An unknown mode exits 2.

The rules live in `agent-type-rules.json`. A judge in `advise` mode, or on tier `opus`, resolves to `advisor`. Other judges resolve to `gate-runner`. An explorer on tier `opus` resolves to `planner`. The types `general-purpose`, `generalist`, and `general` resolve to `explorer`.

Use `t3-run role <role> --depth <n>` only for a wrapper override that names a role.

## References

- [Dispatch protocol](references/dispatch-protocol.md) — read before any child launch. It covers the run ledger, launch, wake, resume, nesting, and cleanup.
- [Result rules](references/result-rules.md) — read before the parent accepts any child result. It covers validation, retry, and SHA integration.

## Files

- `role-map.json` — single source of every role target.
- `agent-type-rules.json` — ordered rules that map an agent type to a role. The first match wins.
- `bin/t3-run` — Node CLI for the ledger, role lookup, result validation, and gates.
