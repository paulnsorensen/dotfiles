---
status: reviewed
last_verified: 2026-08-13
confidence: high
sources:
  - chezmoi/.chezmoidata/omp.yaml
  - renovate.json5
  - chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md
  - chezmoi/dot_omp/private_agent/extensions/milknado-todo-guard.ts
  - milknado.toml
  - tests/config-validation.bats
  - tests/omp-config.bats
  - tests/sync-orchestrator.bats
  - tests/omp-plugins.bats
  - .sync-lib.sh
  - .sync
  - tests/extensions/milknado-todo-guard.test.mjs
  - https://github.com/can1357/oh-my-pi/blob/39c95e5e29b1c8b082059f57421ce445c3dffdd4/docs/tools/todo.md
  - https://github.com/can1357/oh-my-pi/blob/39c95e5e29b1c8b082059f57421ce445c3dffdd4/packages/coding-agent/src/modes/controllers/input-controller.ts
  - https://github.com/can1357/oh-my-pi/blob/39c95e5e29b1c8b082059f57421ce445c3dffdd4/packages/coding-agent/src/extensibility/extensions/types.ts
  - https://github.com/sysid/pi-extensions/tree/main/packages/vim-editor
---
# OMP

OMP 17.2.12 uses Milknado as its sole work tracker. Native Todo and its reminders are disabled in the repo-authoritative chezmoi data, the system prompt assigns planning to Milknado MCP, and a directly discovered input extension consumes `/todo` before OMP can create a disconnected native list.

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

Milknado task completion fails closed when the project defines no quality gates. The root `milknado.toml:1-3` therefore pins `quality_gates = ["just check"]`, reusing the repository's authoritative verification recipe. Every built-in flavor inherits this gate; omitting the key would let agents claim nodes but prevent them from marking verified work done.

`todo.enabled: false` removes the model-facing Todo tool. It does not unregister OMP's separately wired `/todo` command, which can still mutate native session state. Disabling reminders alone therefore does not establish single ownership.

## Vim input mode

`@sysid/pi-vim@1.0.3` provides OMP's modal prompt editor. It starts in INSERT, switches to NORMAL on `Esc`, and exposes the package's Vim motions and edits. The exact npm version lives under `omp.npmPlugins` in `chezmoi/.chezmoidata/omp.yaml`.

`sync_omp_plugins` installs missing or stale managed npm plugins while preserving unrelated user-installed npm plugins. OMP accepts the package's legacy `pi.extensions` manifest through its Pi-compatibility loader. `tests/omp-plugins.bats` proves missing, stale, converged, and unmanaged-package behavior; a live PTY smoke exercised INSERT → NORMAL with text retained.

## Hook isolation

OMP does not receive entries from `agents/hooks/registry.yaml`: the registry synchronizer implements only Claude and Codex backends and its default loop names those two targets.[^1] OMP also disables discovery of the Claude, Codex, and other external harness providers that could import their hooks.[^2]

Instead OMP deploys native extensions under `~/.omp/agent/extensions/`: `cheese-flair.ts`, `rtk.ts`, `milknado-todo-guard.ts`, and `sliced-bread-audit.ts`. The flair extension intentionally runs the same deployed `~/.claude/hooks/session-start-cheese-flair.sh` script, so it shares flair output but is not a registry-hook installation.[^3]

[^1]: `agents/hooks/sync.sh:3-18`, `agents/hooks/sync.sh:75-80`
[^2]: `chezmoi/.chezmoidata/omp.yaml:20-24`, `chezmoi/.chezmoidata/omp.yaml:46-53`
[^3]: `chezmoi/dot_omp/private_agent/extensions/cheese-flair.ts:1-26`, `chezmoi/dot_omp/private_agent/extensions/rtk.ts:1-84`, `chezmoi/dot_omp/private_agent/extensions/milknado-todo-guard.ts:1-15`, `chezmoi/dot_omp/private_agent/extensions/sliced-bread-audit.ts:1-94`

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

- Fresh renders assert `compaction.methodOrder: [snapcompact, remote, soft]` (v18 retired `compaction.strategy`; `has("strategy")` must be `false` — see [[../adr/codex-omp-harness-upgrade-001]]), `composer.shape: box`, `keepRecentTokens: 20000`, no `thresholdTokens`, `task.enableLsp: true`, and `retry.modelFallback: false` (`tests/omp-config.bats:34-80`).
- Drift repair starts with both settings true and verifies they are reset (`tests/omp-config.bats:82-102`).
- The retired-key regression feeds the prior managed document, deletes `compaction.thresholdTokens` through wholesale rendering, and keeps genuinely unknown keys fail-closed (`tests/omp-config.bats:103-129`).
- The managed-file test proves chezmoi deploys the four remaining extension modules and system prompt while `.chezmoiremove` owns removal of `no-fork-all.ts` (`tests/omp-config.bats:307-332`).
- The real apply regression seeds a pre-existing retired extension, applies into an explicit temporary destination with scripts excluded, and verifies deletion plus survival of all four modules (`tests/omp-config.bats:333-359`).
- The extension-contract test executes every remaining extension handler test (`tests/omp-config.bats:361-368`).

Root `dots sync` verifies exact live outputs — currently `omp/18.0.5` (`OMP_PIN` in `packages/sync.sh`, renovate-locked in lockstep with the `.sync` guard literal; see [[../operations/sync-and-chezmoi]]) and `codex-cli 0.153.0` — after package convergence, applies the final chezmoi state under those schemas, and repeats both exact probes after a successful final apply. A failed final apply skips post-apply probes; a failed post-apply probe reports `harness-versions` while retaining upgraded binaries. The focused ordering, mismatch, absence, command-failure, and upgraded-state-retention tests live at `tests/sync-orchestrator.bats:180-548`.

`tests/extensions/milknado-todo-guard.test.mjs:32-62` separately pins exact-command blocking, warning contents, the handled action, negative inputs, the continue action, and absence of spurious notifications. The focused OMP config suite and all remaining extension handler tests pass in the corrective gate.

`tests/config-validation.bats:9-15` proves the project config exists, parses as TOML, and resolves the exact `just check` gate. `milknado agents check` validates base agent resolution; a direct profile probe confirmed that `implement`, `spec`, `spike`, `prototype`, and `research` all inherit `just check`.

## Remaining policy

Completed request graphs remain durable in Milknado. This cutover does not decide whether old graphs should be retained permanently, archived, or deleted; any lifecycle policy must preserve the single-owner rule and be implemented in Milknado rather than reintroducing native Todo state.

_Source: OMP Todo-to-Milknado research, guarded cutover, Codex/OMP upgrade verification, and live modal-editor smoke · Updated: 2026-08-13 · Supersedes: native OMP Todo ownership_
