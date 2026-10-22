# Dispatch protocol

The parent is the T3 thread. It launches children with `delegate_task` and tracks them in a run ledger. The parent is never dispatched and has no role in the role map.

## Start

Run this check only at depth 0 (the prompt has no `T3-Depth` line). At depth 1 or more, skip it. The depth cap still applies.

1. Call `orchestrator_capabilities`.
2. Read `inheritedModel`.
3. When `inheritedModel` is not `claude-opus-5-5`, warn the user and ask before any child launch.

The wrapper frontmatter pins the parent to Opus. The check warns when the inherited model differs.

## Run ledger

The ledger is `.cheese/t3/<run>.json`. Create it with `t3-run ledger init <run>`. `t3-run` is on PATH.

- Run id: one id per `t3-*` skill invocation, for example `<skill>-<UTC timestamp>`. It is not the T3 `childRunId`.
- clientRequestId: run `t3-run ledger reserve <run> --phase <p> --role <r> --depth <child depth>`. It prints the next id.
- Reuse a clientRequestId only for a transport retry of the same call.
- A validation retry is a new call.
- Call `reserve` again for the retry.
- Give the retry its own `t3-run ledger record` entry.

Ledger commands:

```text
t3-run ledger {init|reserve|record|complete|status|barrier} <run> ...
```

## Launch

1. Get the target with `t3-run role ... --depth <child depth>`. It prints `{role, providerInstanceId, model, options, isolation}`. The CLI refuses depth 3 or more before launch.
2. Reserve the clientRequestId. Call `delegate_task` with the target, the role's `isolation` value, and `mode: async`.
3. Pass only `providerInstanceId`, `model`, and `options` into the `target` of `delegate_task`.
4. Keep the printed `role` for the ledger. Never pass it as the top-level `role` parameter of `delegate_task`.
5. Run `t3-run ledger record` with the clientRequestId and the `taskId`. Do this before the turn ends.
6. End the turn.

Never fan out with `mode: wait`. Wait calls run one at a time (probe S-5).

## Wake

Wake on a completion notification. Or read `task_status` for each pending ledger entry.

1. Run `t3-run ledger complete` for each terminal child.
2. Run `t3-run ledger barrier <run> <phase>`.
3. Advance the phase only when the barrier exits 0.

## Resume

1. Run `t3-run ledger status <run>`. It lists the unfinished children.
2. Read each one with `task_status`.
3. Never relaunch a child whose ledger entry is terminal.

[TBD] A stored `taskId` is proven to resolve only within one parent session. Whether it resolves after a full T3 service restart is unverified.

## Write roles

A write role has `isolation: worktree` in the role map. A worktree child starts from the parent's last commit. Uncommitted edits do not copy.

1. Commit before you delegate.
2. T3 names the child branch. Do not choose it.

## Nesting

- Start every task prompt with a `T3-Depth: <n>` line. The parent's children are depth 1.
- A thread whose prompt has no `T3-Depth` line is depth 0. A child prompt gets the sender's depth + 1.
- A child that runs a dispatching phase uses the matching `t3-*` wrapper.
- A child at depth 2 must not dispatch. It runs its phase inline.
- Refuse any dispatch that would reach depth 3.

## Age router override

The age router may override the reviewer effort from the role map. The router value wins for that call.

## Cleanup

After integration, the parent removes each child worktree that it integrated. Use `git worktree remove`.

Open question: the spec lists this as [TBD]. It is not settled whether the parent or a T3 tool owns this step.
