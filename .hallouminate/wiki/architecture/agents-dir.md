# The `agents/` Registry System

`agents/` is the harness-agnostic source of truth for everything an AI coding agent needs that varies by *content* but not by *harness*: MCP servers, cross-cutting hooks, cheese sub-agent definitions, the system-prompt body, and the shared name/quote bank. One set of registries, rendered into five different on-disk layouts (Claude Code, Codex, opencode, Cursor, Copilot) by the `ap` tool.

The split that matters: **`agents/` declares *what*; `ap` (the `agent-profile/` package) decides *where and in what shape*.** This page covers the *what* — the registries and their conventions. The renderer mechanics live in the companion page [[agent-profile]].

## Why registries instead of per-harness config

Each harness wants its config in a different place and format — Claude reads a plugin tree, Codex reads `~/.codex/config.toml` + `.codex/agents/*.toml`, opencode reads a merged `opencode.json`, etc. Maintaining five copies of "install the tilth MCP" by hand drifts immediately. So the repo keeps one declarative registry per concern and renders all five.

The registries are also the stable **edit surface**: `mcp-edit`, `hook-edit`, `agent-edit`, `skill-edit` open the relevant YAML. You never hand-edit a rendered artifact — you edit a registry and re-run the deploy.

## The four registries (one per concern)

| Concern | File | Edit alias | Shape |
|---|---|---|---|
| MCP servers | `agents/mcp/registry.yaml` | `mcp-edit` | name-keyed mapping |
| Hooks | `agents/hooks/registry.yaml` | `hook-edit` | name-keyed mapping |
| Sub-agents | `agents/registry.yaml` | `agent-edit` | name-keyed mapping |
| Skills | `skills/_registry.yaml` (external) + `skills/` tree (local) | `skill-edit` | sources + dir tree |

These four are unioned by the `base` profile — the only profile that reads *all four* registries (see `profiles/base/profile.yaml`). The isolated profiles (`fe`, `review`, `spec`, `notion`, `todo`, `plugin`, `rtkonly`) are closed worlds that do *not* `include: [base]`; each references the agents registry directly via `registries: {agents: agents/registry.yaml}`. Everything downstream — every harness layout — flows from the `base` union.

### MCP registry — `agents/mcp/registry.yaml`

A mapping of `name → {command, args, env, scope, harnesses, gate_unless, optional, description}`. The non-obvious fields:

- **`harnesses`** (default `[claude, codex, opencode, cursor]`) — membership list. Each renderer filters the MCP list to entries that include its own name. The defaults differ slightly per renderer, encoded as `_MCP_DEFAULT` constants in each renderer rather than in the registry.
- **`gate_unless`** (claude-only) — `gate_unless: CHEESE_FLOW` means "skip this entry under Claude when `$CHEESE_FLOW == "true"`". The cheese-flow plugin ships its own `context7`/`tavily`/`tilth` via the plugin's bundled `.mcp.json`; registering them user-scope too would spawn duplicate processes. Codex/opencode have no plugin system, so the gate is ignored there and the entry installs normally (`base.gate_blocks` returns `False` for any non-claude harness).
- **`optional`** — when true, the entry is dropped *non-fatally* at ingest if any `${VAR}` it references is unset (e.g. `todoist` without `TODOIST_API_KEY`). A non-optional entry with an unset ref fails the install loud.
- **`scope`** (claude-only) — `user`/`project`/`local`; other harnesses have no scope concept.

#### Per-harness `args`/`env` via Go templates

A handful of MCP values must differ per harness. The registry expresses this with Go-template syntax against `$h` (the active harness), e.g. serena's `SERENA_MUX_HARNESS: '{{ if eq $h "claude" }}claude-code{{ else }}{{ $h }}{{ end }}'`. The leading comment line `# {{ $h := env "HARNESS" }}` documents the binding.

`ap` renders this per-value: `agent_profile/templating.py:render_value` shells out to `chezmoi execute-template` only for strings containing `{{` (the common bare-string case incurs zero subprocess overhead), prepending the same `{{ $h := env "HARNESS" }}` preamble so `$h` resolves. A missing `chezmoi` binary falls back to the unrendered string with a one-time stderr warning rather than crashing — `ap` doesn't hard-depend on chezmoi.

Note: the bash-style `${VAR}` env refs (resolved from `$DOTFILES_DIR/.env`) are a *separate* pass from the Go-template pass and are untouched by it.

### Hook registry — `agents/hooks/registry.yaml`

A mapping of `name → {event, script|command, shared_assets, harnesses, matcher, timeout, async, description}`. Key design points:

- **`script` vs `command` are mutually exclusive.** `script` is a repo-relative path that gets *deployed* (copied) into the harness layout; `command` is a literal string used verbatim with no file deploy. The **Claude** renderer raises loudly if both or neither is set (`claude.py`); the Codex/Cursor/Copilot renderers assume `script` and silently ignore a stray `command`, so the both/neither invariant is enforced only under Claude.
- **`shared_assets`** — repo-relative data files the hook script reads at runtime (its lib + bank). Each must live under `agents/<subdir>/<file>` and is deployed to `~/.<harness>/<subdir>/<file>`. Because the chezmoi installer derives its copy list from this field, *adding a new hook with new assets is a pure registry edit* — no installer change.
- **`harnesses`** defaults to **claude-only** (every renderer's hook default is `("claude",)`); any other harness needs an explicit opt-in. opencode has no hook renderer at all, so it never receives hooks regardless. The shipped cheese-flair hook lists `[claude, codex]` explicitly.
- **`matcher`** — event-and-harness-dependent. Only `(PreToolUse, PostToolUse)` write a matcher under Claude; `SessionStart` writes one only under Codex (a `startup|resume|clear` source regex). The valid-events set and the matcher rules live in `agents/hooks/lib.sh`; the claude renderer re-encodes the claude half as `_CLAUDE_MATCHER_EVENTS = {PreToolUse, PostToolUse}` and that pair must stay in sync with lib.sh.
- **`async`** (claude-only boolean) — an explicit `false` is preserved (distinct from absent).

#### The self-locating hook (why `shared_assets` works)

`agents/hooks/session-start-cheese-flair.sh` injects rotating cheese flair at session start. It must run identically under `~/.claude/` and `~/.codex/`, so it resolves its lib and bank *relative to its own deployed path* (`$SCRIPT_DIR/../lib`, `$SCRIPT_DIR/../reference`), not the source. It deliberately uses `BASH_SOURCE[0]` *without* canonicalizing symlinks: the lib/bank live canonically under `agents/lib/` + `agents/reference/` and are *copied* (not symlinked) into the harness layout, so resolving a symlink back to `$DOTFILES/claude/` would miss them. This is the critical reason `shared_assets` deploy paths drop the leading `agents/` segment (`base.shared_asset_relpath`): `agents/lib/cheese-flair.sh` → `~/.<harness>/lib/cheese-flair.sh`, exactly where the script looks.

### Agent registry — `agents/registry.yaml`

The cheese sub-agents. Metadata lives in the registry; instruction bodies live as frontmatter-free Markdown at `body_path` under `agents/agent_definitions/`. This split keeps all per-harness metadata in one YAML file while bodies stay editable prose.

- **`models` is per-harness**: `{claude: sonnet, codex: gpt-5-codex, cursor: claude-sonnet, opencode: inherit}`. Each renderer reads its own key; `inherit`/absent means "no override". Copilot ignores model overrides.
- **`tools` / `disallowedTools` are lists.** Renderers join to CSV for Claude/Cursor frontmatter, and *derive* sandbox/read-only intent for Codex (`sandbox_mode = "read-only"`) and opencode (`permission.edit: deny`). The read-only derivation (`shared.agent_is_read_only`) counts the MCP write surfaces — `mcp__tilth__tilth_write`, serena's symbol editors — not just `Edit`/`Write`, and treats a trailing-`*` grant like `mcp__serena__*` as conferring write.

Two tiers live here: narrow specialists (`fromage-*`, `ghostbuster`, `nih-scanner`, `ricotta-reducer`, `roquefort-wrecker`, `duckdb-expert`, `whey-drainer`, `worktree-triage`) used as fork targets, and four general phase agents (`explorer`/`researcher`/`reviewer`/`coder`) modelling the explore→research→review→code loop. Planning is intentionally *not* an agent: it owns the human-approval loop and a level-1 sub-agent can't fan out, so it stays an orchestrator concern.

The four phase agents hand results back through their **final message**, which the harness returns to the orchestrator as the tool result; each opens that message with the four-field handoff block (`status` / `next` / `artifact` / one-line orientation) defined in `agents/preamble.md`'s *Cross-phase handoff* section. That block is the deliberate in-session twin of the `/wheypoint` slug — same four fields, `blocked:` where wheypoint uses `halt:`. The agents do **not** call `/wheypoint` on clean completion: `/wheypoint` is the cross-session baton and explicitly disclaims per-phase handoffs. The one sanctioned exception is the context budget — when an agent approaches ~120k tokens (or exhausts its window mid-task) it stops at a safe checkpoint and returns `status: blocked: out of context` with `artifact:` pointing at a partial slug (`.cheese/notes/<slug>.md` for the coder, its own `.cheese/<phase>/` artifact for the read-only three) so the orchestrator re-dispatches a fresh agent from that slug instead of losing progress (`agents/preamble.md`'s *Cross-phase handoff* spells out the orchestrator side). The same ~120k threshold rides on the tool-call wrap-up signal of the heavier fork specialists (`ricotta-reducer`, `ghostbuster`, `nih-scanner`, `fromage-fort`): they finalize partial output and flag the unscanned scope so the orchestrator can re-dispatch the remainder.

### Skills — `skills/` tree + `skills/_registry.yaml`

Two sources unioned at ingest (`ingest._expand_skills`):

- **Local**: every `skills/<name>/SKILL.md` becomes a `path:` item, copied into each harness by the renderers.
- **External**: `_registry.yaml`'s `sources: {OWNER/REPO: {pin, skills}}` becomes `source:` items, *not* copied by renderers — they're fetched at install time via `npx skills add` (one shallow `git clone` per source repo, installed to all harnesses in one call; see `cli._fetch_external_skills`).

## The edit → render → deploy workflow

1. **Edit a registry** (`mcp-edit` / `hook-edit` / `agent-edit` / `skill-edit`).
2. **`ap` renders.** The `base` profile expands the four registries into one item list; `ap`'s five renderers materialize that list per harness. The unified manual deploy entry point is `base-sync`, which dispatches the live wrapper profiles (`global` for the dot-dir harnesses, `opencode-global` for opencode).
3. **chezmoi drives it on `dots sync`** via `run_onchange_after_install-base-profile.sh.tmpl`, which forks to `chezmoi/lib/install-base-profile.sh` and runs `ap install global` (dot-dir harnesses) + `ap install opencode-global` (opencode). The run_onchange hash covers `base`, `global`, `_permissions`, `opencode-global`, all registry inputs, the hook scripts, the shared-asset libs, *and* the `ap` renderer source — so editing a renderer, live wrapper, permission floor, or hook script re-deploys on the next plain `dots sync`.

The standalone `agents/mcp/sync.sh` and `agents/hooks/sync.sh` still exist for the legacy native-CLI path but are **no longer the deploy path** — `dots sync` does not run them.

## The non-registry files in `agents/`

Shared agent *content* that chezmoi copies directly (not through `ap`):

- **`agents/AGENTS.md`** — global coding-agent preferences. chezmoi copies it to `~/.claude/CLAUDE.md` *and* `~/.codex/AGENTS.md` (via `install-agents-doc.sh`).
- **`agents/preamble.md`** — the system-prompt body (MCP tool-routing tables + pre-call self-check). It *replaces* the bundled system prompt per harness: Codex via `model_instructions_file` in `config.toml`, opencode via `~/.config/opencode/agents/build.md` (both wired by `install-prompts.sh`), Claude via `--system-prompt-file` in the `cc`/`ccc`/`ccr` wrappers (`zsh/claude.zsh`). The user-side AGENTS.md/CLAUDE.md cascade loads *on top of* this replaced prompt.
- **`agents/RTK.md`** — RTK proxy reference, Claude-only (copied to `~/.claude/RTK.md`).

See [[../harnesses/index]] for how each harness consumes these artifacts and the official docs for its native config surfaces.
