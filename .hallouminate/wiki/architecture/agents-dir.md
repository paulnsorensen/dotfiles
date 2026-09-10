# The `agents/` Registry System

`agents/` is the shared source for MCP servers, cross-cutting hooks, sub-agent definitions, system-prompt content, and the common name/quote bank. `ap` lowers compatible registries into four layouts (Claude, Codex, Cursor, Copilot); the OMP assembler consumes selected shared assets through its native chezmoi tree.

The split that matters: **`agents/` declares shared content; each harness adapter owns its native shape.** `ap` is one adapter, not the owner of every live harness.

## Why registries instead of per-harness config

Harnesses want different native shapes: Claude uses a plugin tree, Codex uses `config.toml` plus agent TOML, Cursor uses MCP/plugin files, Copilot uses its own MCP and hook schemas, and OMP uses a native package tree. One shared declaration with explicit adapters prevents those copies from drifting.

The registries are also the stable **edit surface**: `mcp-edit`, `hook-edit`, `agent-edit`, `skill-edit` open the relevant YAML. You never hand-edit a rendered artifact — you edit a registry and re-run the deploy.

## The four registries (one per concern)

| Concern | File | Edit alias | Shape |
|---|---|---|---|
| MCP servers | `agents/mcp/registry.yaml` | `mcp-edit` | name-keyed mapping |
| Hooks | `agents/hooks/registry.yaml` | `hook-edit` | name-keyed mapping |
| Sub-agents | `agents/registry.yaml` | `agent-edit` | name-keyed mapping |
| Skills | `skills/_registry.yaml` (external) + `skills/` tree (local) | `skill-edit` | sources + dir tree |

These four are unioned by the `base` profile — the only profile that reads *all four* registries (see `profiles/base/profile.yaml`). The isolated profiles (`fe`, `review`, `spec`, `mgmt`, `todo`, `plugin`, `rtkonly`) are closed worlds that do *not* `include: [base]`; each references the agents registry directly via `registries: {agents: agents/registry.yaml}`. Everything downstream — every harness layout — flows from the `base` union.

### MCP registry — `agents/mcp/registry.yaml`

A mapping of `name → {command, args, env, scope, harnesses, gate_unless, optional, description}`. The non-obvious fields:

- **`harnesses`** — explicit membership list. The current shared default is the four `ap` targets; individual renderers can narrow their fallback, so read the renderer constant when absence semantics matter.
- **`gate_unless`** (Claude-only) — skips an MCP when the named environment flag is active, avoiding duplicate plugin-owned and user-scope servers. Non-Claude renderers ignore it.
- **`optional`** — drops an entry non-fatally when a referenced environment variable is absent. Managed entries now use the credential broker, so this mainly survives for profile-local MCPs.
- **`scope`** (Claude-only) — `user`, `project`, or `local`.

#### Per-harness `args`/`env` via Go templates

A handful of MCP values must differ per harness. The registry expresses this with Go-template syntax against `$h` (the active harness), e.g. `'{{ if eq $h "claude" }}claude-code{{ else }}{{ $h }}{{ end }}'`. The leading comment line `# {{ $h := env "HARNESS" }}` documents the binding.

The mechanism is live but **currently unexercised** — its only real user was serena's `SERENA_MUX_HARNESS`, and serena is retired ([[serena-retirement]]). Expect to be the first to re-use it, and expect no existing entry to copy from.

`ap` renders this per-value: `agent_profile/templating.py:render_value` shells out to `chezmoi execute-template` only for strings containing `{{` (the common bare-string case incurs zero subprocess overhead), prepending the same `{{ $h := env "HARNESS" }}` preamble so `$h` resolves. A missing `chezmoi` binary falls back to the unrendered string with a one-time stderr warning rather than crashing — `ap` doesn't hard-depend on chezmoi.

Note: the bash-style `${VAR}` env refs (resolved from `$DOTFILES_DIR/.env`) are a *separate* pass from the Go-template pass and are untouched by it.

### Hook registry — `agents/hooks/registry.yaml`

A mapping of `name → {event, script|command, shared_assets, harnesses, matcher, timeout, async, description}`. Key design points:

- **`script` vs `command` are mutually exclusive.** `script` deploys a repo file; `command` is literal. Claude validates the invariant; the other renderers consume script-backed entries.
- **`shared_assets`** — runtime files copied beside a hook under the target harness tree.
- **`harnesses`** defaults to Claude-only; every additional renderer requires explicit membership.
- **`matcher`** is event- and harness-specific: Claude emits tool matchers, while Codex accepts a session-source matcher.
- **`async`** is a Claude-only boolean.

#### The self-locating hook (why `shared_assets` works)

`agents/hooks/session-start-cheese-flair.sh` injects rotating cheese flair at session start. It must run identically under `~/.claude/` and `~/.codex/`, so it resolves its lib and bank *relative to its own deployed path* (`$SCRIPT_DIR/../lib`, `$SCRIPT_DIR/../reference`), not the source. It deliberately uses `BASH_SOURCE[0]` *without* canonicalizing symlinks: the lib/bank live canonically under `agents/lib/` + `agents/reference/` and are *copied* (not symlinked) into the harness layout, so resolving a symlink back to `$DOTFILES/claude/` would miss them. This is the critical reason `shared_assets` deploy paths drop the leading `agents/` segment (`base.shared_asset_relpath`): `agents/lib/cheese-flair.sh` → `~/.<harness>/lib/cheese-flair.sh`, exactly where the script looks.

### Agent registry — `agents/registry.yaml`

The cheese sub-agents. Metadata lives in the registry; instruction bodies live as frontmatter-free Markdown at `body_path` under `agents/agent_definitions/`. This split keeps all per-harness metadata in one YAML file while bodies stay editable prose.

- **`models` is per-harness**: each renderer reads its own key; `inherit` or absence means no override. The Copilot renderer emits `models.copilot` as one pinned `model:` line (Copilot CLI ≥ 1.0.83 honors it; before that it was stripped). No `model-policy` or fallback list is emitted — a list would need a registry schema change across every renderer, so it stays a follow-up. The phase agents leave `models.copilot` unset on purpose.
- **`maxTurns` is Claude frontmatter**: the shared Claude/Cursor file carries it, Claude honors it, and Cursor ignores it.[^max-turns]
- **`tools` / `disallowedTools` are lists.** Claude/Cursor render CSV frontmatter; Codex derives sandbox/read-only intent. `shared.agent_is_read_only` also counts MCP write surfaces, not only `Edit`/`Write`.

Two tiers live here: narrow specialists (`ghostbuster`, `nih-scanner`, `roquefort-wrecker`, `duckdb-expert`, `whey-drainer`, `worktree-content-digest`) used as fork targets by dotfiles-local skills, and four general phase agents (`explorer`/`researcher`/`reviewer`/`coder`) modelling the explore→research→review→code loop. The former `/age` fork specialists (`fromage-age-arch`, `fromage-age-history`, `fromage-secaudit`, `fromage-fort`, `ricotta-reducer`) were removed 2026-07-31 — the reduced `/age` + `age-fanout` workflow dispatches only `explorer`/`reviewer` workers, leaving them dispatcher-less (see [[agent-vs-skill-tiering]]). Planning is intentionally *not* an agent: it owns the human-approval loop and a level-1 sub-agent can't fan out, so it stays an orchestrator concern.

The four phase agents hand results back through their **final message**, which the harness returns to the orchestrator as the tool result. Each agent body carries the same four-line handoff block (`status` / `next` / `artifact` / one-line orientation), and `tests/phase-agent-handoff.bats` locks the four copies byte-identically rather than treating the preamble as their schema owner.[^handoff] The block is the in-session twin of the `/wheypoint` slug. Agents do **not** call `/wheypoint` on clean completion; when context is exhausted, their role-owned handoff rules checkpoint durable state and tell the orchestrator which fresh phase agent should continue. The heavier fork specialists (`ghostbuster`, `nih-scanner`) use the same principle: finalize partial output and flag unscanned scope before their context limit.

#### Dispatch gates are mechanical, not prose (2026-09-10, dotfiles#952)

Sixty days of Claude session analytics (609 `Agent` dispatches) showed three agent-side gates never fired as prose: 72 of 148 reviewer dispatches had no `Review mode:` line and zero returned blocked; 0% of coder dispatches carried `Done means`, yet none refused; taste-tests ran up to six Opus rounds on one draft. The definitions now make each gate a verbatim block the worker copies rather than composes:

- `reviewer.md` scans for the literal `Review mode:` before any tool call and returns a fixed `blocked: missing-contract` handoff otherwise. Round ≥ 3 of a taste-test returns `blocked: taste-loop` so the parent asks the user. `taste-test` is declared sufficient at `default` power / `medium` effort (its fix-rate matched severity-report at the same prompt size, so the `powerful` tier added cost without signal — easy-cheese#659).
- `coder.md` returns `blocked: missing-contract` when **both** `Done means` and `Scope fence` are absent; one missing field still asks. The resume brief's Gates section records the worktree path and base SHA so a resumed coder reuses the worktree (26 cold installs in one session was the trigger).
- `preamble.md` carries five numbered **Dispatch gates** and two table changes: `coder` is "not under `/age`" (39 of 67 age-span coders were cure work that `/cure` owns) and `whey-drainer` gets a row (1 spawn in 60 days because coders ran gates themselves).

Generic prompts (`preamble.md`, `agent_definitions/*.md`) use the easy-cheese tier vocabulary `cheap | default | powerful` plus effort, never a model name, so one body serves every harness (paulnsorensen/easy-cheese#659 `routing-policy.md`). Each harness binds the tiers where it owns models:

| Tier | Claude (`model:` per dispatch) | Codex (`models.codex`, pinned per agent toml) | OMP (`modelRoles` alias, pinned in agent frontmatter) |
|---|---|---|---|
| `powerful` | `opus` | `gpt-5.6-sol` — reviewer | `@strong` (Sol) — reviewer, cheese-reviewer |
| `default` | `sonnet` | `gpt-5.6-terra` — researcher, generalist, ghostbuster | `@balanced` (Terra) |
| `cheap` | `haiku` | `gpt-5.6-luna` — coder, explorer, whey-drainer, scanners | `@fast` (Luna; `task`, `tiny`, `smol`) — coder |

Only Claude honors a per-dispatch tier, so a `taste-test` at `default` is a Claude-only saving today; Codex and OMP run the reviewer's pinned `powerful` model for both modes. Bindings live in `preamble.md` (Claude + Codex), `chezmoi/dot_omp/private_agent/APPEND_SYSTEM.md` (OMP), and as comments in `codex.yaml` and the registry reviewer entry; `tests/phase-agent-handoff.bats` locks them. A cross-harness `tier:` registry field mapped per renderer was proposed (#952 item 6) and deferred as a design call. See [[omp-agent-model-effort]] for the Codex/OMP workload matrix.

### Skills — `skills/` tree + `skills/_registry.yaml`

Two sources unioned at ingest (`ingest._expand_skills`):

- **Local**: `skills/<name>/SKILL.md` becomes a `path:` item for `ap`; OMP copies the selected local set into its exact chezmoi tree.
- **External**: `_registry.yaml` sources are fetched by `npx skills add` for CLI-supported harnesses and vendored by the chezmoi assembler for OMP, honoring each source's `harnesses:` filter.

Pure-prompt, user-invoked skills marked `disable-model-invocation: true` are the model-policy exception: they inherit the session model and omit `model` and `effort`. The tier→effort gate skips these inline skills but still enforces explicit matching fields for selected workflow skills.[^inline-skill-model]

[^inline-skill-model]: `skills/wat/SKILL.md:1-7`; `tests/agent-skill-model-effort.bats:80-106`

## The edit → render → deploy workflow

1. **Edit the appropriate source.** Shared registry commands cover MCP, hooks, agents, and skills; native OMP settings stay in its own `.chezmoidata` registry.
2. **Render or assemble.** `ap` compiles explicit profiles for Claude, Codex, Cursor, and Copilot. `.sync-lib.sh` assembles the exact Claude, Codex, and OMP payload trees.
3. **Deploy with `dots sync`.** Chezmoi applies native files, then harness-specific reconcilers converge CLI-managed MCPs and packages. `ap install global` is no longer the machine-convergence path.

The standalone `agents/mcp/sync.sh` and `agents/hooks/sync.sh` remain legacy native-CLI helpers; `dots sync` does not call them.

## The non-registry files in `agents/`

Shared agent *content* that chezmoi copies directly (not through `ap`):

- **`agents/AGENTS.md`** — global coding-agent preferences installed as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
- **`agents/preamble.md`** — the compact standing system-prompt body. Claude wrappers pass it with `--system-prompt-file`; `install-prompts.sh` installs it as Codex's `model_instructions_file`. OMP uses a separate native `APPEND_SYSTEM.md` because its prompt contract differs.
- **`agents/RTK.md`** — RTK proxy reference, Claude-only (copied to `~/.claude/RTK.md`).

See [[../harnesses/index]] for how each harness consumes these artifacts and the official docs for its native config surfaces.

[^max-turns]: Verified against Claude Code 2.1.195 local binary strings (`xLl` parser reads frontmatter `maxTurns` and stores `maxTurns`; invalid values warn "Must be a positive integer") and implemented in `agent-profile/agent_profile/shared.py:144` plus `agents/registry.yaml:27` (the first `maxTurns:` entry).
[^handoff]: `agents/agent_definitions/{explorer,researcher,reviewer,coder}.md`, `tests/phase-agent-handoff.bats:18-42`

*Source: preamble and coder prompt consolidation · Updated: 2026-07-28 · Supersedes: preamble-owned phase handoff schema*
