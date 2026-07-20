---
status: reviewed
last_verified: 2026-07-20
confidence: high
sources:
  - chezmoi/.chezmoidata/omp.yaml
  - chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md
  - chezmoi/dot_omp/private_agent/extensions/milknado-todo-guard.ts
  - tests/omp-config.bats
  - tests/extensions/milknado-todo-guard.test.mjs
  - https://github.com/can1357/oh-my-pi/blob/39c95e5e29b1c8b082059f57421ce445c3dffdd4/docs/tools/todo.md
  - https://github.com/can1357/oh-my-pi/blob/39c95e5e29b1c8b082059f57421ce445c3dffdd4/packages/coding-agent/src/modes/controllers/input-controller.ts
  - https://github.com/can1357/oh-my-pi/blob/39c95e5e29b1c8b082059f57421ce445c3dffdd4/packages/coding-agent/src/extensibility/extensions/types.ts
---
# OMP

OMP uses Milknado as its sole work tracker. Native Todo and its reminders are disabled in the repo-authoritative chezmoi data, the system prompt assigns planning to Milknado MCP, and a directly discovered input extension consumes `/todo` before OMP can create a disconnected native list.

## Ownership contract

- Create one Milknado goal for each user request that needs a plan.
- Add executable work as child task nodes, claim a task before starting it, and mark it done only after verification.
- Address updates by Milknado node ID. Never mirror the same work in native Todo or another tracker.
- Milknado is project-scoped and durable; native OMP Todo is session-scoped and reconstructed from session state. The durability difference is why two active trackers would diverge.

The policy is injected through `chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md:31-35`. Milknado itself was already registered as an OMP MCP server, so the cutover required no second server definition (`chezmoi/dot_omp/private_agent/mcp.json:18-20`).

## Repo-authoritative configuration

Disable Todo in `chezmoi/.chezmoidata/omp.yaml`, never by hand-editing the generated live OMP config:

```yaml
todo:
  enabled: false
  reminders: false
```

These values live at `chezmoi/.chezmoidata/omp.yaml:68-70`. The config renderer owns both keys, so a live value of `true` is reset on the next apply. Before the cutover, OMP 17.0.5 reported both values as `true`; `prewalk.enabled` was `false` and `tools.xdev` was `true`.

`todo.enabled: false` removes the model-facing Todo tool. It does not unregister OMP's separately wired `/todo` command, which can still mutate native session state. Disabling reminders alone therefore does not establish single ownership.

## `/todo` guard

`chezmoi/dot_omp/private_agent/extensions/milknado-todo-guard.ts:3-13` handles the remaining command path. The guard:

1. Matches only `/todo` followed by whitespace or end-of-input.
2. Returns `{ action: "continue" }` for ordinary text such as `/todone` or `Use /todo later`.
3. Warns `Native /todo is disabled. Use Milknado MCP for work tracking.` for an exact command.
4. Returns `{ action: "handled" }`, which consumes the input before built-in slash-command dispatch.

OMP still advertises the built-in `/todo` completion. An extension input handler can consume execution but cannot remove that built-in autocomplete entry. Removing the completion requires an upstream OMP change.

The action shape is part of the OMP input-event protocol. `{ handled: true }` is not equivalent: a fresh-context review caught that initially incorrect shape before publication, and the implementation plus regression assertions were revised to use `action: "handled"` and `action: "continue"`.

## Native Todo behavior left behind

OMP's native Todo is not just a model tool. Its implementation also has slash-command edits, session custom entries, transcript reminder injection, resume-time restoration, visible Todo UI updates, and failure reminders. The public Todo documentation at the pinned source commit records those collaborators and confirms that tool availability is gated separately by `todo.enabled`.

The guarded direct cutover intentionally gives up that native-looking UI and session restoration. Milknado's graph and MCP tools are the durable replacement; this repo does not emulate the native renderer or reminder loop.

## Alternatives considered

| Design | Decision | Reason |
| --- | --- | --- |
| Direct MCP only | Rejected | Lowest maintenance, but stale `/todo` could still create a second native list. |
| Guarded direct cutover | Chosen | Keeps one durable owner with a small, explicit command guard. |
| Todo-shaped extension adapter | Rejected | Current ExtensionAPI exposes no MCP `callTool` facade, so the adapter would need its own MCP client/process and a second stdio connection. |
| OMP `TodoBackend` seam | Deferred upstream | A backend seam plus public MCP-call facade is the only design that can preserve the native tool, command, reminders, session state, and TUI without duplicating transport code. |
| Native Todo plus Milknado | Rejected | Two planning systems have different persistence and status semantics and will drift. |

A compatibility adapter also has unresolved semantic and loading problems:

- Milknado has no exact native `abandoned` state. A Todo `drop` operation would need an explicit mapping to `blocked` with a reason, deletion, or a new Milknado status.
- Extension tool shadowing can currently replace a built-in tool named `todo`, but that is implementation behavior rather than a stable documented contract.
- Marketplace-installed OMP plugins do not automatically load extension modules. An adapter would need direct auto-discovery, an npm extension install, or `omp plugin link`.

Do not build that adapter unless native-looking Todo behavior becomes a requirement. If it does, prefer the upstream backend/MCP facade seam over maintaining a private second MCP transport.

## Verification surface

`tests/omp-config.bats` protects the deployment contract:

- Fresh renders assert both Todo settings are false (`tests/omp-config.bats:34-53`).
- Drift repair starts with both settings true and verifies they are reset (`tests/omp-config.bats:76-95`).
- The managed-file test proves chezmoi deploys the guard and system prompt (`tests/omp-config.bats:279-305`).
- The extension-contract test executes every extension handler test (`tests/omp-config.bats:297-310`).

`tests/extensions/milknado-todo-guard.test.mjs:32-62` separately pins exact-command blocking, warning contents, the handled action, negative inputs, the continue action, and absence of spurious notifications. The implementation handoff recorded a green 15-test OMP config suite, a green two-test guard suite, and a clean prompt-policy markdown lint run.

## Remaining policy

Completed request graphs remain durable in Milknado. This cutover does not decide whether old graphs should be retained permanently, archived, or deleted; any lifecycle policy must preserve the single-owner rule and be implemented in Milknado rather than reintroducing native Todo state.

_Source: OMP Todo-to-Milknado research and guarded-cutover handoff · Updated: 2026-07-20 · Supersedes: native OMP Todo ownership_
