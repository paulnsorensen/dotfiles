# ADRs — workflow-decomposition

Decisions behind composing the saved workflows in `claude/workflows/` from shared modules, a deterministic effects tool, and child workflows. Spec: durable corpus `specs/workflow-decomposition.md` (`~/.local/share/cheese/paulnsorensen-dotfiles/`). Evidence: 48 move-my-cheese runs from 2026-10-12 to 2026-10-16 landed no plan end to end; see [[architecture/saved-workflows]].

## ADR-001: Build every layer in one spec  [status: accepted]

- **Context:** The decomposition has about 25 parts in three layers: pure modules, an effects tool, and child workflows. A wave-1-only spec is easier to review.
- **Decision:** One spec makes every layer A, B, and C part runnable work. Agent roles (layer D) are a follow-up.
- **Alternatives:** Wave 1 only (preflight, integrate, probe, guard, call), with later waves on hold. The user rejected it to avoid a long tail of half-adopted parts.
- **Consequences:** About 11 curds in 5 stacked layers. Each layer must be green before the next one lands.

## ADR-002: The effects tool is Node, not bash  [status: accepted]

- **Context:** The Workflow runtime has no shell or filesystem, so git and `gh` steps were English instructions in prompts. Repo convention puts shell logic in bash with Bats tests.
- **Decision:** `bin/wfx` is a bash shim that runs `claude/workflow-fx/cli.mjs`. The tool prints one JSON envelope per subcommand and has `node --test` tests against real temporary git repos and a fake `gh`.
- **Alternatives:** Bash plus Bats. Rejected because multi-step git work with JSON output is fragile in bash, and Node can load the same layer A modules as the workflows.
- **Consequences:** One source of truth for staleness, graph, and guard logic across scripts and the tool. The shim keeps `lint-shell` clean. Node becomes a runtime need for workflow runs.

## ADR-003: Rewire move-my-cheese with behaviour changes  [status: accepted]

- **Context:** The live failures sat in the final integration barrier, the replan-on-any-move staleness rule, and agent environments that lacked pytest or write access.
- **Decision:** move-my-cheese runs `wfx preflight` before the first planner, integrates each target as it is built, rebases instead of replanning when only `main` moved, and loads approved plans from `wfx run-state`.
- **Alternatives:** Swap copies for modules with no behaviour change, or build parts with no callers. Both leave the live failures in place.
- **Consequences:** Highest-risk curd in the spec. A live sandbox landing is the acceptance check, because offline tests stub every agent.

## ADR-004: One shared typed() core with hooks  [status: accepted]

- **Context:** ADR-014 in [[adr/cheese-factory-workflow]] kept a per-workflow `typed()`. By 2026-10-16 the three forks differed: move-my-cheese lets a throw escape, cheese-board turns it into null, and cheese-factory retries read-only throws and reports `lost`.
- **Decision:** The `call` module holds one `typed()` with the cheese-factory base shape. Script-specific steps plug in as hooks: `normalize`, `expandShas`, `onWorktree`, `nullIsFinal`, and `retryOnThrow`. This supersedes the ADR-014 sentence "Each workflow keeps its own `typed()`."
- **Alternatives:** Keep per-script `typed()` and accept the drift.
- **Consequences:** A `typed()` change reaches all three scripts. One unit test per hook pins each script's path.

## ADR-005: Per-module marker blocks instead of one prelude block  [status: accepted]

- **Context:** `sync.mjs` pastes one prelude block per script and requires exactly one marker pair. ADR-014 requires the deployed file to equal the repo file.
- **Decision:** Each module lives in `claude/workflow-prelude/modules/<name>.js` with a header that names what it provides and requires. `sync.mjs` replaces each `// BEGIN module <name>` block. `load.mjs` evaluates a module for tests and for `wfx`.
- **Alternatives:** Keep one prelude block, so every script carries every helper; concat at deploy, which ADR-014 rejected.
- **Consequences:** Scripts include only what they use. The deploy rule from ADR-014 still holds. A duplicate-definition test stops new local copies.
