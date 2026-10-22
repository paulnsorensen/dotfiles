---
name: t3-core
description: >
  Shared core for the `t3-*` skills: the T3 override block, the dispatch
  protocol, the result rules, and the role map. Not run directly. Each
  `t3-*` wrapper points here.
user-invocable: false
---

# t3-core

This skill is the shared core for the `t3-*` wrapper skills. Do not run it directly.

## T3 override block

Every `t3-*` wrapper names this block. A wrapper follows its real skill or workflow source. It applies only these two overrides.

1. **Dispatch.** Send every subagent through the T3 `delegate_task` tool. Follow [the dispatch protocol](references/dispatch-protocol.md). Do not use native host subagents.
2. **Targets.** Take each dispatch target only from `bin/t3-run role <role>`. The command prints `{providerInstanceId, model, options, isolation}` for the role.

`bin/t3-run` is on PATH as `t3-run`; call it as `t3-run` from any repository.

Model ids live only in `role-map.json`. Do not write a model id in a wrapper or a reference. One exception: the AC-5 parent check in `dispatch-protocol.md` names `claude-opus-5-5`.

## References

- [Dispatch protocol](references/dispatch-protocol.md) — read before any child launch. It covers the run ledger, launch, wake, resume, nesting, and cleanup.
- [Result rules](references/result-rules.md) — read before the parent accepts any child result. It covers validation, retry, and SHA integration.

## Files

- `role-map.json` — single source of every role target.
- `bin/t3-run` — Node CLI for the ledger, role lookup, result validation, and gates.
