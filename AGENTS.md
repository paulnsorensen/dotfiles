# AGENTS.md

Project instructions for any coding agent working in this repository — Claude Code, Cursor, Codex, Copilot CLI, Antigravity, and friends. The root `CLAUDE.md` imports this file via `@AGENTS.md`, so harnesses that key off `CLAUDE.md` still pick it up.

## Repository Overview

This is a personal dotfiles repository that configures a vim-centric, terminal-based development environment for macOS. The configuration focuses on zsh shell, iTerm2, VS Code with vim bindings, comprehensive git setup, and Claude Code integration.

## Key Commands

### Dotfiles Management

- `dots sync` - Sync dotfiles (symlinks, packages, fonts) with rollback support
- `dots sync refresh` - Force re-check all packages (bypass cache)
- `dots upgrade` (or `dots up`) - Upgrade installed packages (brew/cargo/npm/uv tools)
- `dots update` - Pull latest changes and run sync
- `dots status` - Show git status of dotfiles
- `dots rollback [id]` - Rollback to a previous state
- `dots backups` - List available backups
- `dots doctor` - Run health checks and profile shell
- `dots test` - Run test suite (validates shell loading, git hooks, symlinks, and Claude config sync)

### Shell Configuration

- `zrl` - Reload zsh configuration after changes
- `source ~/.zshrc` - Alternative way to reload configuration

### Claude Code & MCP Management

- `cc` - Launch claude (pass-through to `claude`)
- `ccc` - Continue last conversation (`claude --continue`)
- `ccr` - Resume conversation (`claude --resume`)
- `dots profile launch claude <name>` - Launch a scoped profile from `profiles/<name>/profile.yaml` (the harness-agnostic `ap` tool; supersedes the retired `ccp`). `dots profile list` lists profiles; `dots profile describe <name>` shows the resolved manifest. Isolated profiles reproduce the old `ccp` closed-world launch (strict MCP scope, `--setting-sources ""`, `--tools`, system-prompt append, permissions deny, env, extra_args).
- `ccw <slug>` - Create isolated git worktree and launch Claude inside it (sandboxed)
- `ccw-init <slug>` - Create/resume a worktree (used by ccw and /worktree skill)
- `ccw-ls` - List git worktrees
- `ccw-sweep` - Scan ~/Dev for stale worktrees with safety checks (dry-run, auto-clean modes)
- `ccw-clean` - Clean stale worktrees in current repo only (delegates to ccw-sweep)
- `wt-git <path> <cmd>` - Run git commands in a worktree without cd (avoids safety heuristics)
- `ccfresh` - Continue last conversation with MCPs primed
- `claude-settings` - Edit ~/.claude/settings.json
- `mcp-edit` - Edit MCP registry.yaml (the per-type edit surface)
- `mcp-sync` - Deploy via the unified `ap` path (`dots profile install base`) — renders the registry-derived `base` profile into every harness
- `mcp-ls` - List currently configured MCPs
- `mcp-add <name> <cmd> [args...]` - Add a user-scoped MCP
- `hook-edit` - Edit hook registry.yaml (the per-type edit surface)
- `hook-sync` - Deploy via the unified `ap` path (`dots profile install base`)
- `hook-ls` - List configured hooks
- `claude-json-prune` - Preview stale project entries in ~/.claude.json (dry run)
- `claude-json-prune --apply` - Remove stale entries (creates timestamped backup first)

### GitHub Helpers

- `gh-pr-review <PR#>` - Bundle PR metadata, diff, and checks for review
- `gh-pr-prep` - Bundle PR prep context (commits, diff stats, upstream status)
- `gh-issue-context <issue#>` - Bundle issue metadata and comments
- `gh-pr-batch <PR#> [PR# ...]` - Batch status (title, state, mergeable, files) for multiple PRs
- `gh-pr-checks-batch <PR#> [PR# ...]` - Batch CI checks for multiple PRs

### Plugin Management

- `plugin-sync` - Sync plugins from registry.yaml to Claude Code
- `plugin-sync-dry` - Preview plugin sync changes without applying
- `plugin-edit` - Edit plugin registry.yaml
- `plugin-ls` - List currently installed plugins
- `cf-refresh` - Rebuild the cheese-flow plugin cache from `~/Dev/cheese-flow` (use after editing the plugin in-place)
- `plugin-refresh <plugin> [marketplace]` - Generic version of cf-refresh for any local plugin (defaults to cheese-flow@local)

### Agent Skill Management (`npx skills add`)

Harness-agnostic — installs into each agent listed in `SKILL_HARNESSES` (`.env`). Skills (local `skills/` tree + external `_registry.yaml` sources) deploy through the registry-derived `base` profile rendered by `ap`. `dots sync` drives the render via chezmoi's `run_onchange_after_install-base-profile.sh.tmpl`; external sources fetch via `npx skills add` (the Vercel `skills` CLI), which `git clone`s each source repo once and installs to every requested agent in one call. Requires `npx` (Node) — `dots sync` exits 1 if it's missing. No GitHub auth: `npx skills` clones public repos.

- `skill-edit` - Edit `skills/_registry.yaml` (the per-type edit surface)
- `skill-sync` - Deploy via the unified `ap` path (`dots profile install base`)
- `skill-ls` - List installed global skills (`npx skills list --global`)

### Common Development Tasks

- `lb` - Open daily logbook (creates markdown file at `~/psorensen/logbook/[date].md`)
- `uuidg` - Generate UUID and copy to clipboard
- `cdd` - Navigate to ~/Dev directory
- `hms` - Run home-manager switch (for Nix package updates)

## Architecture & Structure

```
dotfiles/
├── bin/                    # CLI tools (dots command)
├── agents/                 # Harness-agnostic agent config (shared by Claude + Codex + opencode)
│   ├── AGENTS.md           # Global coding-agent preferences. Copied to ~/.claude/CLAUDE.md AND ~/.codex/AGENTS.md by chezmoi.
│   ├── RTK.md              # RTK proxy reference (Claude only — copied to ~/.claude/RTK.md by chezmoi).
│   ├── registry.yaml       # Cheese sub-agent source of truth (metadata + body_path); rendered into every harness by ap.
│   ├── agent_definitions/  # Agent bodies (instruction-only Markdown referenced by registry.yaml's body_path).
│   ├── mcp/
│   │   ├── registry.yaml   # MCP source of truth (per-entry `harnesses: [claude, codex, opencode]`)
│   │   └── sync.sh         # Declarative MCP sync — loops over harnesses; claude/codex use native CLIs, opencode jq-edits ~/.config/opencode/opencode.json.
│   ├── hooks/
│   │   ├── registry.yaml   # Hook source of truth (per-entry `harnesses: [claude, codex]`, matcher, timeout)
│   │   ├── sync.sh         # Declarative hook sync — jq-edits claude/settings.json + yq-edits ~/.codex/config.toml.
│   │   ├── lib.sh          # Per-harness backend helpers (drift signature, upsert, detect).
│   │   └── session-start-cheese-flair.sh  # SessionStart hook — self-locating; deployed to both harnesses.
│   ├── lib/
│   │   └── cheese-flair.sh # Weighted name generator + quote picker (used by the SessionStart hook).
│   └── reference/
│       └── cheese-flair.md # The names + quote bank read by cheese-flair.sh.
├── profiles/               # Scoped sessions (base + global + fe, notion, plugin, review, rtkonly, spec, todo) as `profiles/<name>/profile.yaml` — deployed/launched via the `ap` tool (`dots profile`). `base` = registry-derived render primitive; `global` = live install (target=$HOME, registers `local` marketplace, enables `global@local`)
├── claude/                 # Claude Code-specific configuration
│   ├── commands/           # Slash commands (/spec, /wreck, /test, etc.)
│   ├── hooks/              # Pre-tool hooks
│   └── plugins/            # Plugin registry; `plugins/local/` holds in-repo plugins (cheese-flow, todoist-flow)
├── codex/                  # OpenAI Codex CLI-specific configuration
│   └── config.toml         # Base ~/.codex/config.toml — copied on first install only, then user-owned (MCP entries written by sync.sh).
│                           # opencode TUI/config lives under chezmoi/dot_config/opencode/ (theme + tui.json always-managed; opencode.json scaffolded once).
├── cursor/                 # Cursor-specific configuration
│   └── plugins/local/      # In-repo Cursor plugins (cheese-grok) deployed by chezmoi to ~/.cursor/{skills,rules,commands,hooks}/ plus hooks.json/modes.json merges.
├── skills/                 # Single source of truth for skills — flat tree of skill dirs plus `_registry.yaml` for external (`npx skills add`) sources. Unioned into the `base` profile and rendered into every harness by `ap`.
├── chezmoi/                # chezmoi source dir. Wires `~/.config/chezmoi/chezmoi.toml` (via `.chezmoi.toml.tmpl`, prompts for email on first run), renders templated dotfiles (`private_dot_gitconfig.tmpl`, `private_dot_copilot/mcp-config.json.tmpl`), and runs run_onchange scripts: install-base-profile (renders the registry-derived `base` profile — MCPs + skills + hooks — into every harness via `ap`; supersedes the retired install-mcp/install-hooks/install-claude-skills deploy scripts), install-agents-doc (agents/AGENTS.md → both harnesses, agents/RTK.md → Claude), install-codex (codex/config.toml → ~/.codex/ first-time only), install-agent-profile (warms the `ap` uv env).
├── packages/
│   ├── packages.yaml       # Flat package registry (brew, cargo, apt)
│   └── sync.sh             # Package sync with hash cache
├── fonts/                  # Font installation (.sync script)
├── prek.toml               # Pre-commit hooks config (prek)
├── iterm2/                 # iTerm2 preferences
├── skhd/                   # skhd hotkey daemon config
├── reference/              # Reference docs (gitignored)
├── .claude/
│   └── specs/              # Tabled feature specs (.claude/specs/<slug>.md)
├── vim/                    # Vim configuration
├── vimrc                   # Vim settings
├── zsh/                    # Modular zsh configuration
│   ├── aliases.zsh         # Shell aliases
│   ├── claude.zsh          # Claude Code & MCP aliases
│   ├── colors.zsh          # Chocolate Donut color palette
│   ├── completion.zsh      # Zsh completion system
│   ├── core.zsh            # Core environment setup
│   ├── fzf.zsh             # Fuzzy finder setup
│   ├── prompt.zsh          # Custom powerline prompt
│   └── skhd.zsh            # skhd reload alias
├── zshrc                   # Main zsh entry point
├── .sync-with-rollback     # Main sync script with state management
├── AGENTS.md               # This file — agent instructions for the repo
└── CLAUDE.md               # One-line `@AGENTS.md` import for Claude Code
```

### Configuration Hierarchy

1. **zshrc** - Main entry point that sources all zsh modules
2. **zsh/** - Modular configuration files, each handling specific functionality
3. **claude/** - Claude Code configuration (agents, commands, hooks, MCP)

### Key Design Patterns

- **Modular Configuration**: Each aspect of the shell is in its own file for maintainability
- **Theme Consistency**: Chocolate Donut theme managed via tinty across terminal, git, and iTerm2
- **Performance Optimization**: Git prompt uses caching to avoid slowdowns
- **Declarative MCP Management**: Single YAML registry at `agents/mcp/registry.yaml`, applied to every installed harness (Claude, Codex, opencode). Claude/Codex use their native `mcp add/remove` CLIs; opencode has no non-interactive CLI, so the sync jq-edits `~/.config/opencode/opencode.json` in place.
- **Rollback Support**: Sync creates backups and manifests for easy rollback
- **Scoped Profiles**: `profiles/<name>/profile.yaml` declares task-shaped sessions (base, global, fe, notion, plugin, review, rtkonly, spec, todo) owned by the `ap` tool. `base` is the registry-derived render primitive; `global` wraps it with the install-overlay (`target_default: $HOME`, claude marketplace + plugin enablement) and is what `dots sync` runs against the live config. `dots profile launch claude <name>` launches; isolated profiles reproduce the old `ccp` closed-world (strict MCP scope, `--setting-sources ""`, tool whitelist, system-prompt append, permissions deny, env, extra_args).

## MCP (Model Context Protocol) Management

MCPs are managed declaratively via `agents/mcp/registry.yaml`. One registry, multiple harnesses:

```yaml
mcps:
  context7:
    command: npx
    args: ["-y", "@upstash/context7-mcp"]
    scope: user                                # claude-only — codex/opencode ignore
    harnesses: [claude, codex, opencode]       # optional; default is all three
    gate_unless: CHEESE_FLOW                   # claude-only — skip install when plugin provides it
    description: Documentation context for libraries and frameworks
```

**Per-entry fields:**

- `harnesses` (optional) — list of harness names to install into. Default: `[claude, codex, opencode]`.
- `scope` (claude-only) — `user`, `project`, or `local`. Codex/opencode have no scopes.
- `gate_unless` (claude-only) — skip install when env var equals `"true"` (defer to a plugin's bundled MCP).
- `optional` — when `true`, skip this MCP non-fatally if any `${VAR}` it references is unset, instead of failing the sync. For MCPs gated on a credential the user may not have configured (e.g. `todoist` without `TODOIST_API_KEY`).

**Per-harness backends:**

- **claude** — native `claude mcp add/list/remove/get` (text; scope-aware).
- **codex** — native `codex mcp add/list/remove --json` (no scopes).
- **opencode** — no non-interactive CLI; the sync jq-edits `~/.config/opencode/opencode.json` directly. Set `OPENCODE_CONFIG` to override the target path (used by tests). On first run the sync seeds a minimal `{"$schema": ".../config.json"}` file if absent.

**Per-harness `args` via Go templates.** `agents/mcp/sync.sh` runs the registry through `chezmoi execute-template` once per harness with `HARNESS=<claude|codex>` exported. The registry preamble aliases that into `$h` so entries can branch inline without restating the env lookup. Default to `{{ $h }}` so new harnesses inherit their bare name without another schema edit. Serena uses this:

```yaml
{{- $h := env "HARNESS" -}}
...
serena:
  command: serena
  args:
    - start-mcp-server
    - --context={{ if eq $h "claude" }}claude-code{{ else }}{{ $h }}{{ end }}
    - --project-from-cwd
```

The bash-style `${VAR}` env substitution used by `env:` blocks runs in a later pass (`mcp_build_env_flags`) and is untouched by the templating step.

**Filtering which tools an MCP exposes.** No MCP-spec-level mechanism exists; the practical answers are:

- **Server-side (uniform across harnesses):** the cleanest path when supported by the server. Serena reads `~/.serena/serena_config.yml` — set `excluded_tools` (blacklist), `included_optional_tools` (whitelist additions), or `fixed_tools` (exact tool set, replaces defaults). Per-harness `--context=claude-code|codex` already excludes Read/Write/Bash duplicates upstream.
- **Claude-side:** `mcp__<server>__<tool>` glob patterns in `permissions.allow` / `permissions.deny` (used by `profiles/*/profile.yaml`).
- **Codex-side:** per-tool filtering is not exposed by `codex mcp` — only per-server enable/disable.

**Workflow:**

1. Edit registry: `mcp-edit`
2. Apply changes: `mcp-sync` (= `dots profile install base`) or let `dots sync` drive it via chezmoi's `run_onchange_after_install-base-profile.sh.tmpl`, which renders the registry-derived `base` profile into every harness through `ap`.

The `base` profile unions the three separate registries (`agents/mcp/registry.yaml`, `agents/hooks/registry.yaml`, `skills/`); `ap`'s renderers materialize them per harness. (The standalone `agents/mcp/sync.sh` lib remains for the legacy native-CLI sync path but no longer runs on `dots sync`.)

## Hook Management

Harness-agnostic hooks (Claude SessionStart / Codex `[[hooks.SessionStart]]`, etc.) are declared in `agents/hooks/registry.yaml`. One registry, one source of truth, deployed to every harness:

```yaml
hooks:
  session-start-cheese-flair:
    event: SessionStart
    script: agents/hooks/session-start-cheese-flair.sh
    harnesses: [claude, codex]
    matcher: "startup|resume"   # codex-only — claude ignores
    timeout: 5                  # seconds (both harnesses)
    description: Rotating cheese flair sample injected at session start
```

**Per-entry fields:**

- `event` — Claude / Codex event name. Only `SessionStart` is currently wired; the backends in `agents/hooks/lib.sh` fail loud on any other value. Extend the backends before registering `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, or `Stop` entries.
- `script` — repo-relative path; chezmoi deploys to `~/.<harness>/hooks/<basename>`.
- `shared_assets` (optional) — list of repo-relative paths under `agents/<subdir>/<file>` that the hook script reads at runtime (libs, banks, …). Each is deployed to `~/.<harness>/<subdir>/<file>`. Adding a new hook is a pure registry edit — the chezmoi installer iterates `hooks` and copies every `(script ∪ shared_assets) × harnesses` pair.
- `harnesses` (optional) — list; default `[claude, codex]`.
- `matcher` — codex-only regex against the event's `source` field (`startup|resume|clear` for SessionStart). Claude SessionStart entries do not use matchers and the field is ignored there.
- `timeout` — seconds (verified against `developers.openai.com/codex/hooks` — "timeout is in seconds"; Claude uses the same unit).
- `description` — human-readable purpose.

**Workflow:**

1. Edit registry: `hook-edit`
2. Apply changes: `hook-sync` (= `dots profile install base`) or let `dots sync` drive it via chezmoi's `run_onchange_after_install-base-profile.sh.tmpl`. The hook + its `shared_assets` (lib/bank) deploy through `ap`'s claude/codex renderers, which copy the self-locating SessionStart script alongside its assets under the harness layout.

The hook script is self-locating: it resolves its lib and bank from `$SCRIPT_DIR/../lib` and `$SCRIPT_DIR/../reference`, so the same file runs identically under each harness. (The standalone `agents/hooks/sync.sh` lib remains for the legacy upsert path but no longer runs on `dots sync`.)

## Plugin Management

Plugins are managed declaratively via `claude/plugins/registry.yaml`:

```yaml
plugins:
  claude-md-management@claude-plugins-official:
    description: Audit and improve CLAUDE.md files
    scope: user
```

**Prerequisites:**
Marketplaces must be added first:

```bash
claude plugin marketplace add anthropics/claude-plugins-official
claude plugin marketplace add upstash/context7
```

**Workflow:**

1. Edit registry: `plugin-edit`
2. Preview changes: `plugin-sync-dry`
3. Apply changes: `plugin-sync`
4. Restart Claude Code for changes to take effect

Note: Unlike MCP, the plugins directory is NOT symlinked to ~/.claude because
Claude Code uses that location for plugin cache storage.

## Cursor Plugins

Cursor plugins live under `cursor/plugins/local/<name>/` and follow the Cursor 2.5 plugin spec — a `.cursor-plugin/plugin.json` manifest plus bundled `skills/`, `rules/`, `commands/`, `hooks/`, `hooks.json`, and `modes/`. Source-of-truth is in this repo; chezmoi deploys the contents to Cursor's user-level auto-discovery directories.

```
cursor/plugins/local/cheese-grok/
├── .cursor-plugin/plugin.json    # manifest (name, version, description, keywords)
├── skills/<name>/SKILL.md        # Cursor-compatible Agent Skills
├── rules/*.mdc                   # always-on or path-scoped rules
├── commands/*.md                 # slash commands (NO frontmatter, unlike Claude)
├── hooks/*.sh + hooks.json       # beforeShellExecution / stop / etc.
├── modes/<name>.json             # custom modes merged into ~/.cursor/modes.json
└── README.md + LICENSE
```

**Deploy targets** (driven by `chezmoi/lib/install-cursor-plugin.sh`):

| Source | Target |
|--------|--------|
| `skills/<name>/` | `~/.cursor/skills/<name>/` |
| `rules/*.mdc` | `~/.cursor/rules/*.mdc` |
| `commands/*.md` | `~/.cursor/commands/*.md` |
| `hooks/*.sh` | `~/.cursor/hooks/*.sh` (executable) |
| `hooks.json` | merged into `~/.cursor/hooks.json` |
| `modes/<name>.json` | merged into `~/.cursor/modes.json` under `.modes.<name>` |

Per-target manifests at `<target>/.dotfiles-managed-<plugin>` track ownership so items dropped from the source are removed on the next sync, and user-authored files are preserved. Hook + mode entries are tagged with `_plugin: "<name>"` so re-deploys can strip stale entries without touching unrelated ones.

**MCPs for Cursor** flow through `agents/mcp/registry.yaml` like every other harness — the cursor backend in `agents/mcp/lib.sh` jq-edits `~/.cursor/mcp.json` (`mcpServers` schema, identical to Claude Desktop's). `CURSOR_CONFIG` overrides the target path for tests.

**Workflow:**

1. Edit plugin source: `cursor-plugin-edit` (opens `cursor/plugins/local/` in `$EDITOR`).
2. Apply: `cursor-plugin-sync` (or `dots sync`, which runs `chezmoi apply --force` and dispatches the run_onchange installer).
3. Verify: `cursor-plugin-ls`.
4. Restart Cursor for skills/rules/modes changes to take effect.

The shipping plugin is `cheese-grok` — reader-first grokking + anti-slop design-doc authoring. See `cursor/plugins/local/cheese-grok/README.md` for trigger phrases and contents.

## opencode Settings

opencode's user-wide settings live under `chezmoi/dot_config/opencode/` and apply to `~/.config/opencode/`:

- `opencode.json` (`create_opencode.json` source) — first-run scaffold with `formatter: true` (built-in formatters on save). Chezmoi's `create_` prefix means this is never overwritten on subsequent applies, so the MCP sync (and any manual edits) survive.
- `tui.json` — always-managed. Sets `theme: "chocolate-donut"` and rebinds `editor_open` to `ctrl+o` so the text box can pop out to `$EDITOR` (vim). opencode has no native modal vim editing in the input; this is the closest workflow.
- `themes/chocolate-donut.json` — always-managed. Custom opencode theme derived from `theme/schemes/chocolate-donut.yaml` (the base24 palette).

MCP entries are managed by `agents/mcp/registry.yaml` (see [MCP Management](#mcp-model-context-protocol-management)) — `mcp-sync` jq-writes the `mcp` object into `~/.config/opencode/opencode.json` without touching the rest of the file.

**Migrating from a hand-rolled `opencode.jsonc`:** the scaffold writes to `opencode.json`, not `.jsonc`. If you already have a non-trivial `~/.config/opencode/opencode.jsonc`, merge its contents into `opencode.json` and delete the `.jsonc` (opencode reads either, having both is just confusing).

## Local LLM Stack

A bespoke local-LLM stack (`~/local-llm/`) — llama.cpp workers behind a LiteLLM proxy at `http://127.0.0.1:4000/v1` (dummy key `sk-local`) exposing OpenAI-compatible model names (`local-sonnet`, `local-haiku`, `local-coder`, `local-opus`, `local-vision`, `local-classifier`). It is **per-machine and opt-in**, gated by the chezmoi `localLLM` flag.

**Enable on a machine:** `dots sync` prompts `Manage local LLM stack on this machine?` on first init (persisted to `~/.config/chezmoi/chezmoi.toml`; re-prompt by deleting that file). When **off**, `.chezmoiignore` skips the whole tree so nothing deploys.

**What's managed (in-repo):**

- `chezmoi/local-llm/configs/litellm.yaml` → `~/local-llm/configs/litellm.yaml` (proxy routing + fallbacks).
- `chezmoi/local-llm/scripts/{aliases,install-npu,healthcheck,download-models}.sh` → `~/local-llm/scripts/`.
- `chezmoi/dot_config/systemd/user/{litellm,local-llm.target,worker-*}` → `~/.config/systemd/user/` (verbatim; `%h`-portable, no secrets). Unit *files* only — enablement stays a runtime action.
- opencode `local-llm` provider — `chezmoi/lib/install-local-llm.sh` jq-merges the `.provider` block into `~/.config/opencode/opencode.json` (mirrors the MCP `.mcp` sync), driven by `run_onchange_after_install-local-llm.sh.tmpl`, which also runs `systemctl --user daemon-reload`. Edit models/endpoint there, not in the live file.

**What's NOT managed (runtime / prerequisites):** the 85G `~/local-llm/models/`, the built `~/local-llm/bin/` (llama.cpp + lemonade), `~/local-llm/logs/`, and the `~/.local/bin/litellm` install. The sync never auto-enables or starts workers — that stays explicit (`llm-up`).

**Commands** (aliases from `scripts/aliases.sh`) — these require a manual one-time `echo 'source ~/local-llm/scripts/aliases.sh' >> ~/.zshrc` (per `local-llm/README.md`); the managed `zshrc` does not source them, mirroring how `bin/` and the litellm install are manual prerequisites:

- `llm-up` / `llm-down` / `llm-status` — start/stop/inspect via systemd.
- `llm-test` (`= healthcheck.sh`) — smoke test: hard tiers (litellm + worker-igpu + worker-cpu) must answer with non-empty completions; optional tiers are informational and flagged when served by a LiteLLM fallback. `llm-test --opencode` adds an end-to-end probe through the wired provider.
- `llm-download` (`= download-models.sh`) — on-demand, idempotent GGUF fetch (skips present files). Never run by sync.
- `dots doctor` runs `healthcheck.sh --quiet` automatically when the stack is deployed (presence-gated on `~/local-llm/scripts/healthcheck.sh`).

**Add/tune a model:** add a worker unit under `chezmoi/dot_config/systemd/user/` → add the route to `litellm.yaml` → add the model name to the provider block in `chezmoi/lib/install-local-llm.sh` → `chezmoi apply` (runs `daemon-reload`) → `llm-test`.

> The three Qwen3 repo IDs in `download-models.sh` (sonnet/haiku/coder) are `<unverified>` — they follow the unsloth `<Model>-GGUF` convention of the confirmed opus repo but weren't recorded on the source machine. Confirm on huggingface.co before a fresh-machine download (`hf download` fails loud on a wrong repo).

## Profile System

Profiles are scoped sessions declared as `profiles/<name>/profile.yaml` (repo root) and owned end-to-end by the harness-agnostic `ap` tool (`dots profile`). The retired `ccp` zsh launcher is gone — `dots profile launch` is the single path.

A `profile.yaml` declares `mcps` / `skills` / `commands` / `agents` / `hooks` (registry-entry supersets — a registry entry *is* a profile item) plus, for isolated profiles, the launch-overlay fields:

- `isolated: true` — closed world: `ap launch` reproduces the old `ccp` semantics (a strict `--mcp-config` from the profile's MCPs only + `--setting-sources ""`).
- `system_prompt: CLAUDE.md` — `--append-system-prompt-file <profile>/CLAUDE.md`.
- `tools: [...]` — `--tools` hard whitelist.
- `permissions_deny: [...]` — generated `settings.json` with `permissions.deny`.
- `env: {...}` — injected into the process before exec.
- `extra_args: [...]` — appended verbatim (`${VAR}` expanded from process env / `.env`).

Plus, for *installable* (non-isolated) profiles, the install-overlay fields:

- `target_default: $HOME` — used by `ap install <name>` when `--target` is not passed. Explicit `--target` > profile default > `Path.cwd()`. `${VAR}` and `~` expand at use-time.
- `marketplaces: {name: path}` — claude-only. Renderer registers each name under `~/.claude/settings.json`'s `extraKnownMarketplaces` as a `directory` source with the expanded path (other harnesses ignore it). `${DOTFILES_DIR}` resolves from process env.
- `enabled_plugins: {<plugin>@<marketplace>: true}` — re-uses the same field as the launch overlay; for non-isolated installs, the claude renderer merges these entries into `~/.claude/settings.json`'s `enabledPlugins` (preserving user-managed siblings). For isolated launches it still writes the ephemeral closed-world settings.

Inline MCP `${VAR}` env refs resolve at launch from `$DOTFILES_DIR/.env`, failing loud when unset (parity with the retired `gen-profile-mcp.sh`).

**Profiles:** `base` (registry-derived union of all MCPs/skills/hooks — pure render primitive useful for staging/inspection; `include: [base]` to layer additively), `global` (live install — wraps base with `target_default: $HOME`, registers the `local` marketplace, enables `global@local`), `fe` (frontend + shadcn/Figma), `notion` (Notion HTTP MCP), `plugin` (plugin dev), `review` (read-only PR review), `rtkonly` (experimental — tilth + rtk), `spec` (discovery dialogue), `todo` (Todoist-only, closed world).

**Install vs render:** `ap install base` renders to `--target/$PWD` — useful for staging or building tarballs but does NOT touch your live config. `ap install global` (no flags) targets `$HOME` and additionally wires the rendered plugin tree into `~/.claude/settings.json` (marketplace + enablement) so Claude actually loads it. `dots sync` runs `ap install global` via `chezmoi/lib/install-base-profile.sh`.

**Launch:** `dots profile launch claude <name> [-- claude args...]` — isolated profiles assemble the closed-world flags; non-isolated render into the harness then exec the bare CLI.
**Inspect:** `dots profile list` / `dots profile describe <name>`.
**Add new:** create `profiles/<name>/profile.yaml` (+ optional `CLAUDE.md`), then `dots sync` (renders `global` which includes `base`) or `dots profile launch` for an isolated profile.

**Gotcha:** an isolated profile's tool surface is the `tools` whitelist + `permissions_deny` it declares — there is no inherited user `settings.json` (`--setting-sources ""`). Add the MCP's own tools to `tools` (or rely on the closed `--mcp-config`) rather than expecting the user allowlist to carry over.

**Gotcha 2:** `enabled_plugins` keys are `<plugin-name>@<marketplace>` where `plugin-name` matches the profile that rendered the tree (the claude renderer writes plugin trees to `.claude/plugins/local/<profile_name>/`). Renaming a profile means updating both the YAML's name AND the `enabled_plugins` reference, else the marketplace entry points at a non-existent plugin.

## Sync System

The `.sync-with-rollback` script provides:

- **Manifest tracking** of all symlinks
- **Per-directory .sync scripts** for custom setup (fonts, iterm2, chezmoi)

> **Migrating to chezmoi (in progress — see `.cheese/specs/chezmoi-consolidation.md`).** The custom symlink + rollback system is being retired in favour of chezmoi pure-copy deployment. **Stage 1 (done):** the backup/restore/rollback subsystem is deleted. `dots rollback` no longer snapshots — it prints the git-backed undo path (`git revert` + `dots sync`); `dots backups`/`dots clean` are removed. The symlink loop in `.sync-with-rollback` is untouched until later stages.

**`bin/` PATH decision (Risk 2 / criterion 7):** `bin/` is **never** copied or symlinked into `$HOME`. It runs live from the clone via `export PATH="$DOTFILES_DIR/bin:$PATH"` in `zsh/core.zsh`. The chezmoi migration keeps this — there is no `dot_bin` source entry — so edits to `dots`/`gh-*` helpers are live immediately with no `chezmoi apply` step. This is the chosen option (PATH-from-clone, not copy-and-apply); it preserves the in-repo dev loop for the repo's own tooling.

**Skip list** (not symlinked to ~, canonical source is `SYNC_SKIP_LIST` in `.sync-lib.sh`, which is sourced by `.sync-with-rollback`):

- `.git`, `.local`, `.worktrees`, `reference`, `packages`, `brew`, `apt`, `agents`, `agent-profile`, `codex`

**Hidden directory dispatch**: visible dirs are iterated by `for file in *` (glob), hidden dirs (starting with `.`) are iterated separately by `sync_hidden_dirs`. Both use the same rule: if `$dir/.sync` exists, run it. `chezmoi/` is a visible dir that owns its own `.sync` and is dispatched via the same mechanism (no SYNC_SKIP_LIST entry needed — the `.sync` short-circuit happens before symlinking).

## Chezmoi-Managed Files

A subset of dotfiles is rendered by [chezmoi](https://chezmoi.io/) instead of symlinked. Chezmoi handles per-machine templating (work vs personal git email), per-OS branching, and secret injection — things plain symlinks can't do. Everything else continues to use the symlink + `.sync` system.

`$DOTFILES` below is the absolute path to your clone of this repo (e.g. `~/Dev/dotfiles`).

**Source:** `chezmoi/` subdirectory of this repo. Currently manages:

- `~/.gitconfig` — `chezmoi/private_dot_gitconfig.tmpl` (templated email, work-only `[url]` redirects)
- `~/.copilot/mcp-config.json` — `chezmoi/private_dot_copilot/mcp-config.json.tmpl` (env-rendered API keys, fails fast if unset)
- `~/.claude/settings.json` — `chezmoi/dot_claude/create_settings.json` (seeded once with the user-owned baseline; `ap install global` then jq-merges `enabledPlugins["global@local"]` + `extraKnownMarketplaces.local` on every run, preserving user-managed siblings). A one-time `run_once_before_migrate-claude-settings.sh` removes the legacy `$DOTFILES/claude/settings.json` symlink before chezmoi seeds.
- `~/.config/opencode/opencode.json` — `chezmoi/dot_config/opencode/create_opencode.json` (analogous: seed once, then `ap install base --target $HOME/.config/opencode --harness opencode` mutates the `mcp` block)
- `~/.claude/skills/`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.codex/config.toml`, and MCP entries — handled by `run_onchange_*` scripts under `chezmoi/.chezmoiscripts/` that fork to helpers in `chezmoi/lib/`

**First-init (interactive):** `dots sync` dispatches to `chezmoi/.sync`, which invokes `chezmoi init --source $DOTFILES/chezmoi` if `~/.config/chezmoi/chezmoi.toml` is missing. The `.chezmoi.toml.tmpl` prompts for: `email`. The answer persists to `~/.config/chezmoi/chezmoi.toml` (alongside the persisted `sourceDir`) and isn't re-prompted.

**Subsequent runs:** `dots sync` calls `chezmoi apply --force` via `chezmoi/.sync`. Non-interactive.

**Non-TTY fallback:** if `dots sync` runs without a controlling terminal (CI, automated provisioning) and the config is missing, `chezmoi/.sync` writes a `sourceDir`-only stub. The subsequent `chezmoi apply` will then fail loudly on any template that reads `[data]` (e.g. the gitconfig email) — none of the apply-time templates declare in-template defaults. Run `dots sync` from a TTY (or `chezmoi init --source $DOTFILES/chezmoi` directly) to populate `[data]`. Missing required env vars (e.g. `CONTEXT7_API_KEY`) likewise fail loud.

**Inspect / debug:**

```bash
chezmoi --source $DOTFILES/chezmoi diff              # what would change
chezmoi --source $DOTFILES/chezmoi data              # dump rendered template namespace
chezmoi --source $DOTFILES/chezmoi execute-template < FILE.tmpl
chezmoi doctor                                       # health check (also wired into `dots doctor`)
```

**Re-prompt:** delete `~/.config/chezmoi/chezmoi.toml` and re-run `dots sync` (or `chezmoi init --source $DOTFILES/chezmoi` directly).

**Adding a file:** drop a templated source under `chezmoi/` using the [chezmoi naming attributes](https://chezmoi.io/reference/source-state-attributes/) (`private_`, `dot_`, `executable_`, `encrypted_`, `.tmpl`). Reference data via `{{ .email }}`, etc. — see the existing templates for patterns. Add a corresponding test to `tests/chezmoi-wiring.bats`.

**Secrets upgrade path:** `mcp-config.json.tmpl` uses `{{ env "..." }}` today. Swap to `{{ onepasswordRead "op://<vault>/<item>/credential" }}` once 1Password CLI is set up; remove the corresponding `.env` entries.

**Hard rules** (from the chezmoi skill):

1. Never commit plaintext secrets to `chezmoi/`. Use `encrypted_` or `{{ env }}` / `{{ onepasswordRead }}`.
2. Never edit chezmoi-managed source files via the target path. Use `chezmoi edit ~/.gitconfig` so templating round-trips correctly.
3. Always `chezmoi --source $DOTFILES/chezmoi diff` before applying when you've changed templates.
4. `prompt*` template functions (`promptStringOnce`, `promptBoolOnce`, …) belong **only** in `.chezmoi.toml.tmpl`. A `prompt*` call inside a regular dotfile template re-prompts on every `apply` / `diff` / `status`, which breaks `dots sync`. Pull the value through `[data]` instead.

**File-naming reference.** Prefix order is rigid and depends on the target type — see [chezmoi source-state attributes](https://chezmoi.io/reference/source-state-attributes/) before adding `encrypted_private_dot_…`-style names. Common prefixes: `dot_` (leading `.`), `private_` (mode 0600), `executable_`, `encrypted_`, `exact_` (dirs: delete unmanaged children — handle with care), `create_` (never overwrite), `modify_` (script/template edits existing target).

## Shell Scripts: Functions Need Tests

**Rule:** every shell function that does real work needs a bats test. `.sync` (and any orchestrator) should fork out to tested functions instead of nesting untestable logic inline.

**Why:** `.sync` runs on every `dots sync`, so a regression there breaks the whole environment. Inline logic inside `.sync` is impossible to exercise without running the full sync against a real `$HOME` — which is slow, destructive, and hard to assert against. Tested helper functions can be invoked from bats with mocked dependencies and asserted on directly.

**How to apply:**

- New shell logic goes into a named function in a sourced library (e.g. `.sync-lib.sh`, `claude/lib/sync-common.sh`, `chezmoi/lib/install-external.sh`), not as a free-floating block inside a `.sync` script.
- The function takes its inputs as arguments (no hidden globals beyond logging colors and explicitly-documented env vars).
- A corresponding `tests/<area>.bats` file exercises every branch the function can take. Mock external commands (`gh`, `claude`, `yq`, `jq`, `chezmoi`) by putting fakes earlier on `$PATH` — see `tests/chezmoi-wiring.bats` and `tests/skills-external.bats` for the pattern.
- `.sync` and the top-level orchestrators stay thin: parse args, source the library, dispatch to functions. If a `.sync` script grows logic that can't be invoked from a test, refactor it into a function first.
- Add new test files to `tests/run-tests.sh` so `dots test` runs them.

## Important Implementation Details

### Git Integration

- Default git email is templated via chezmoi (`{{ .email }}`); set a different address per repo with `git config user.email <addr>` (the `cpersonal` alias is a shortcut)
- Aliases follow oh-my-zsh conventions for familiarity
- Custom `grb` alias rebases from main (not master)
- Kdiff3 configured as merge/diff tool
- **difftastic**: AST-aware structural diff via Tree-sitter (700+ languages). Use `gds` alias for structural diffs, or `git difftool -t difftastic` for side-by-side. Composes with delta (delta handles pager for log/show/blame, difftastic outputs directly to terminal).
- **mergiraf**: AST-aware merge driver. Registered globally via `gitattributes` for all supported languages. Auto-resolves structural conflicts (import reorders, independent additions) and falls back to standard merge for anything it can't handle. Works transparently with merge/rebase/cherry-pick.
- **Merge conflict resolution chain**: mergiraf (auto-resolve structural) → rerere (replay remembered manual resolutions) → kdiff3 (manual)
- Pre-commit hooks via prek (secrets, shellcheck, large files, claude sync)
- **Skipping hooks**: Use `git commit --no-verify` if prek blocks a commit and you need to override (rare)

### Claude Code Integration

Full agent/skill catalog is in `agents/AGENTS.md` (copied to `~/.claude/CLAUDE.md` by chezmoi). Key project-level details:

- Pre-tool hooks: `phantom-file-check.js` (Read), `write-guard.js` + `worktree-guard.js` (Edit/Write/MultiEdit/tilth_write), `bash-guard.js` (Bash — blocks dangerous `rm -rf`), `review-reply-guard.js`. `worktree-guard.js` is opt-out: it enforces inside a git worktree by default; set `CLAUDE_WORKTREE_GUARD=0` to disable, or `CLAUDE_WORKTREE_GUARD_ALLOW=/abs,/abs2` to extend its allowlist (worktree root, `$TMPDIR`, `/tmp`, `~/.claude/`, and any `.cheese/` dir are always allowed).
- Compaction hooks: `pre-compact.sh` saves context, `post-compact.sh` restores with `/trace` suggestion
- Session hooks: `post-fresh-start.sh` (suggests `/trace`), `on-session-end.sh` (detects partings)
- `ccw` worktrees are OS-sandboxed (Seatbelt/macOS) with `autoAllowBashIfSandboxed: true`

### Hotkey Daemon (skhd)

Hotkey daemon for macOS, installed from the `koekeishiya/formulae` brew tap and started as a background service by `skhd/.sync`. Config lives at `skhd/skhdrc` and is symlinked to `~/.skhdrc`. Yabai was removed; the file is intentionally an empty skeleton — add bindings as needed.

- **Reload**: `skr` (alias) or `skhd --restart-service` after editing `skhd/skhdrc`.
- **First-time setup**: grant Accessibility to `skhd` in System Settings → Privacy & Security after `dots sync`.
- **Syntax reference**: <https://github.com/koekeishiya/skhd>. Hotkeys can run any shell command via `$SHELL -c`, support modal/chord modes, application-specific bindings, and key synthesis (`-k`).

## Pre-Commit Hooks (prek)

Pre-commit hooks are managed by [prek](https://prek.j178.dev/) via `prek.toml`. Hooks run automatically on commit and include: trailing whitespace, secret detection, shellcheck, large file checks, and a claude config sync check. Run `prek install` after cloning to set up hooks.

**Always run `dots sync` before committing.** The pre-commit hook verifies that Claude config is synced to `~/.claude/` — if not, the commit will be blocked with a reminder to run `dots sync`. This ensures `~/.claude/settings.json`, agents, commands, hooks, and skills stay in sync with the repo.

## Development Notes

### When Modifying Shell Configuration

1. Changes to prompt require careful testing of git status display
2. The KEYTIMEOUT=1 setting is crucial for vi mode responsiveness
3. Path configurations at the top of zshrc are macOS-specific
4. Run `dots sync` after changes to ensure symlinks are correct

### When Adding New Aliases or Functions

1. Claude/MCP-related items go in `zsh/claude.zsh`
2. General utilities go in `zsh/aliases.zsh`
3. Tool-specific configs get their own file

### When Adding New MCPs, Plugins, LSPs, Packages, or Skills

| Type | Registry | Sync command | Notes |
|------|----------|--------------|-------|
| MCP | `agents/mcp/registry.yaml` | `dots sync` (or `dots profile install global` on a deployed setup) | Restart harnesses after. Unioned into the `base` profile, deployed to `$HOME` via `global`; `ap`'s renderers materialize per harness (claude `.mcp.json` plugin-scoped, codex `config.toml`, opencode/cursor/copilot merged JSON). |
| Hook | `agents/hooks/registry.yaml` | `dots sync` (or `dots profile install global`) | Harness-agnostic SessionStart/etc. hooks; `ap`'s renderers copy the self-locating script + its `shared_assets` (lib/bank) into the plugin tree at `~/.<harness>/plugins/local/global/{hooks,lib,reference}/`. Wiring lives in the plugin's `plugin.json`, NOT in `~/.claude/settings.json`. |
| Plugin (Claude) | `claude/plugins/registry.yaml` | `plugin-sync` | Add `mcp__plugin_<name>__*` to `permissions.allow` if it provides MCP tools |
| Plugin (Cursor) | `cursor/plugins/local/<name>/` (per-plugin manifest at `.cursor-plugin/plugin.json`) | `cursor-plugin-sync` (or `dots sync`) | chezmoi's `run_onchange_after_install-cursor-plugins.sh.tmpl` drives `chezmoi/lib/install-cursor-plugin.sh` per plugin, deploying to `~/.cursor/{skills,rules,commands,hooks}/` and jq-merging `hooks.json` + `modes.json`. Per-collection manifests at `<target>/.dotfiles-managed-<plugin>` track ownership. Restart Cursor after. |
| LSP | `claude/plugins/registry.yaml` (with `load: true`) | `plugin-sync` | Servers start lazily |
| Package | `packages/packages.yaml` | `dots sync` | Use `dots sync refresh` to force re-check |
| Skill | `skills/` (local dirs + `_registry.yaml` for external sources) | `dots sync` (or `skill-sync` = `dots profile install base`) | chezmoi's `run_onchange_after_install-base-profile.sh.tmpl` renders the `base` profile via `ap`: local (`path:`) skills are copied by the renderers, external (`source:`) skills fetch via `npx skills add` (one `git clone` per source, all harnesses in one call). `ap`'s install manifest tracks ownership. |
| Profile | `profiles/<name>/profile.yaml` | `dots profile install <name>` / `dots profile launch claude <name>` | Registry-entry-superset items + (isolated) launch-overlay fields + (installable) install-overlay fields (`target_default`, `marketplaces`, `enabled_plugins`). `base` is registry-derived; `global` wraps base for the live install path; specialized profiles `include: [base]`; isolated profiles are closed worlds (the `ccp` parity). |

## Important Gotchas

1. **Use `dots sync`**: Don't manually symlink - use the sync script for rollback support
2. **macOS Specific**: Paths and some utilities assume macOS environment
3. **Vi Mode**: Shell is in vi mode by default
4. **MCP Scope**: Use `user` scope for dev tools, `project` for team-shared MCPs
5. **Reference Folder**: Put reference docs in `reference/` (gitignored, not symlinked)
6. **zsh Loading Order**: Files in `zsh/` are sourced in the order they appear in `zshrc`. If you add a new config file, edit `zshrc` to source it at the right point. For example, completions must load before `fzf.zsh` or keybindings might conflict.
7. **Pre-Commit Hook Failures**: If prek blocks a commit (e.g., detected secrets), fix the issue before retrying. Only use `--no-verify` for temporary overrides. Check `prek.toml` to understand what's being checked.
