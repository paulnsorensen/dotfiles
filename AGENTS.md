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
- `dots profile <cmd>` - Manage harness-agnostic agent profiles (see "Agent Profiles" below)
- `dots test` - Run test suite (validates shell loading, git hooks, symlinks, and Claude config sync)

### Shell Configuration

- `zrl` - Reload zsh configuration after changes
- `source ~/.zshrc` - Alternative way to reload configuration

### Claude Code & MCP Management

- `cc` - Launch claude (pass-through to `claude`)
- `ccc` - Continue last conversation (`claude --continue`)
- `ccr` - Resume conversation (`claude --resume`)
- `ccp <name>` - Launch a scoped profile from `claude/profiles/<name>/`. Run `ccp` with no args to list available profiles.
- `ccw <slug>` - Create isolated git worktree and launch Claude inside it (sandboxed)
- `ccw-init <slug>` - Create/resume a worktree (used by ccw and /worktree skill)
- `ccw-ls` - List git worktrees
- `ccw-sweep` - Scan ~/Dev for stale worktrees with safety checks (dry-run, auto-clean modes)
- `ccw-clean` - Clean stale worktrees in current repo only (delegates to ccw-sweep)
- `wt-git <path> <cmd>` - Run git commands in a worktree without cd (avoids safety heuristics)
- `ccfresh` - Continue last conversation with MCPs primed
- `claude-settings` - Edit ~/.claude/settings.json
- `mcp-sync` - Sync MCPs from registry.yaml to Claude Code
- `mcp-sync-dry` - Preview MCP sync changes without applying
- `mcp-edit` - Edit MCP registry.yaml
- `mcp-ls` - List currently configured MCPs
- `mcp-add <name> <cmd> [args...]` - Add a user-scoped MCP
- `hook-sync` - Sync harness-agnostic hooks (cheese-flair SessionStart) to Claude + Codex
- `hook-sync-dry` - Preview hook sync changes without applying
- `hook-edit` - Edit hook registry.yaml
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

### Agent Skill Management (`gh skill install`)

Harness-agnostic — installs into each agent listed in `SKILL_HARNESSES` (`.env`). Auto-runs as part of `dots sync` via chezmoi's `run_onchange_after_install-claude-skills.sh.tmpl`, which invokes `chezmoi/lib/install-external.sh`. Requires `gh` (v2.90+ with `skill` subcommand) and `gh auth login` — `dots sync` exits 1 if either is missing.

- `skill-sync` - Install external skills from `skills/_registry.yaml` into each configured harness (also fires during `dots sync` via chezmoi)
- `skill-sync-dry` - Preview skill installs without making changes
- `skill-edit` - Edit `skills/_registry.yaml`
- `skill-ls` - Check installed skills for updates (`gh skill update --all --dry-run`)

### Session Monitoring

- `ccm` - Run Claude session monitor standalone (shows metrics for current directory's session)
- `ccm --cwd DIR` - Monitor a specific directory's session
- `ccm --once` - Print metrics once and exit (for scripting)
- `zjclaude` - Launch zellij with Claude layout (main pane + monitor bar)

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
├── claude/                 # Claude Code-specific configuration
│   ├── agents/             # Cheese-themed specialist agents
│   ├── commands/           # Slash commands (/spec, /wreck, /test, etc.)
│   ├── hooks/              # Pre-tool hooks
│   ├── profiles/           # Scoped sessions (fe, plugin, review, rtkonly, spec, todo) — launched via `ccp <name>`
│   └── plugins/            # Plugin registry; `plugins/local/` holds in-repo plugins (cheese-flow, todoist-flow)
├── codex/                  # OpenAI Codex CLI-specific configuration
│   └── config.toml         # Base ~/.codex/config.toml — copied on first install only, then user-owned (MCP entries written by sync.sh).
│                           # opencode TUI/config lives under chezmoi/dot_config/opencode/ (theme + tui.json always-managed; opencode.json scaffolded once).
├── cursor/                 # Cursor-specific configuration
│   └── plugins/local/      # In-repo Cursor plugins (cheese-grok) deployed by chezmoi to ~/.cursor/{skills,rules,commands,hooks}/ plus hooks.json/modes.json merges.
├── skills/                 # Single source of truth for skills — flat tree of skill dirs plus `_registry.yaml` for external (`gh skill install`) sources. Copied to ~/.claude/skills/ by chezmoi.
├── chezmoi/                # chezmoi source dir. Wires `~/.config/chezmoi/chezmoi.toml` (via `.chezmoi.toml.tmpl`, prompts for email + work on first run), renders templated dotfiles (`private_dot_gitconfig.tmpl`, `private_dot_copilot/mcp-config.json.tmpl`), and runs run_onchange scripts: install-claude-skills (skills/ → ~/.claude/skills/), install-agents-doc (agents/AGENTS.md → both harnesses, agents/RTK.md → Claude), install-codex (codex/config.toml → ~/.codex/ first-time only), install-mcp (drives agents/mcp/sync.sh --force), install-hooks (copies agents/hooks/*, agents/lib/cheese-flair.sh, agents/reference/cheese-flair.md into both harnesses then drives agents/hooks/sync.sh).
├── agent-profile/          # Per-repo profile loader (drives `dots profile`) — installs subsets of the global agents/ registry into a target repo
│   ├── ap                  # Main CLI (list/describe/install/uninstall/launch)
│   ├── lib/                # parse, discover, manifest helpers
│   └── renderers/          # Per-harness emitters: claude.sh (native plugin packager), codex.sh, opencode.sh, cursor.sh, copilot.sh
├── profiles/               # Per-repo profile library — drop-in agent bundles installable into target repos
│   ├── base/               # Generic coding-agent baseline (included by other profiles)
│   └── rust/               # Example language-specific profile
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
- **Scoped Profiles**: `claude/profiles/<name>/` bundles a CLAUDE.md + `settings-merge.json` for task-shaped sessions (frontend, spec, review, rtk-only, plugin, todo). `ccp <name>` launches with profile-merged settings, enabling per-profile LSP gating and tool restrictions.

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
- **Claude-side:** `mcp__<server>__<tool>` glob patterns in `permissions.allow` / `permissions.deny` (used by `claude/profiles/*/settings-merge.json`).
- **Codex-side:** per-tool filtering is not exposed by `codex mcp` — only per-server enable/disable.

**Workflow:**

1. Edit registry: `mcp-edit`
2. Preview changes: `mcp-sync-dry`
3. Apply changes: `mcp-sync` (interactive removal prompts) or let `dots sync` drive it via chezmoi's `run_onchange_after_install-mcp.sh.tmpl` (uses `--force` non-interactively).

`agents/mcp/sync.sh` loops over harnesses; missing harness CLIs are skipped silently.

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
2. Preview changes: `hook-sync-dry`
3. Apply changes: `hook-sync` (or let `dots sync` drive it via chezmoi's `run_onchange_after_install-hooks.sh.tmpl`, which copies the script + lib + bank into each harness's `$HOME/.<harness>/{hooks,lib,reference}/` then runs `agents/hooks/sync.sh`).

`agents/hooks/sync.sh` uses per-harness file backends — `jq` over `claude/settings.json` for Claude, `yq -p=toml` over `~/.codex/config.toml` for Codex. Each upsert is idempotent; every unrelated top-level key (including other SessionStart entries, `[mcp_servers]`, `approval_policy`, …) is preserved. The hook script itself is self-locating: it resolves its lib and bank from `$SCRIPT_DIR/../lib` and `$SCRIPT_DIR/../reference`, so the same file runs identically under `~/.claude/` and `~/.codex/`.

## Agent Profiles (`dots profile`) — per-repo overlay

Per-repo overlay that installs a *subset* of the global `agents/` + `skills/` + `claude/` registries into a target repository. Where `dots sync` + chezmoi handles the **global** layer (every harness, every machine), `dots profile install` handles the **per-repo** layer — drop a focused bundle into the repo you're currently in.

**Discovery order** (first match wins):

1. `$AP_EXTRA_SEARCH_PATHS` entries (colon-separated; also fed by `--profile-src <dir>`) — ad-hoc roots
2. `$PWD/.agent-profiles/<name>/` — per-repo override
3. `$DOTFILES_DIR/profiles/<name>/` — repo-shipped library

**Commands:**

```bash
dots profile list                          # Discover profiles
dots profile describe <name>               # Show resolved (post-include) manifest
dots profile install <name> [--harness h]  # Render into $PWD
dots profile uninstall <name>              # Surgical removal via manifest
dots profile launch <harness> [name]       # Install + exec the harness CLI
```

**Target harnesses:** Claude Code, Codex, opencode, Cursor, Copilot CLI.

**Per-harness mapping** (post-reshape):

| Concept       | Claude                                                | Codex                                       | opencode                                | Cursor                                | Copilot CLI                           |
|---------------|-------------------------------------------------------|---------------------------------------------|-----------------------------------------|---------------------------------------|---------------------------------------|
| Bundle root   | `.claude/plugins/local/<name>/`                       | n/a (no bundle concept)                     | n/a (loose files)                       | n/a (loose files)                     | n/a (loose files)                     |
| Subagent      | plugin `agents/<n>.md`                                | `.codex/agents/<n>.toml` (TOML)             | reads shared `.claude/agents/<n>.md`    | reads shared `.claude/agents/<n>.md`  | `.github/agents/<n>.agent.md`         |
| Skill         | plugin `skills/<n>/SKILL.md`                          | reads shared `.agents/skills/<n>/SKILL.md`  | reads shared `.agents/skills/<n>/SKILL.md` | reads shared `.agents/skills/<n>/SKILL.md` | `.github/skills/<n>/SKILL.md`        |
| Slash command | plugin `commands/<n>.md`                              | skip (deprecated on Codex — use skills)     | `.opencode/commands/<n>.md` (**plural**) | `.cursor/commands/<n>.md`             | skip (no equivalent)                  |
| Hook          | plugin `hooks/` + `plugin.json` event wiring          | `.codex/hooks.json` (6 events)              | skip (TS plugins only)                  | `.cursor/hooks.json` (22 events)      | `.github/hooks/<n>.json` (13 events)  |
| MCP           | plugin `.mcp.json`                                    | `[mcp_servers]` in `.codex/config.toml`     | `opencode.json` `mcp.*`                 | `.cursor/mcp.json` `{mcpServers}`     | `.copilot/mcp-config.json` (requires `tools: ["*"]`) |
| Prose         | shared global `AGENTS.md` (chezmoi)                   | shared global `AGENTS.md` (chezmoi)         | shared global `AGENTS.md` (chezmoi)     | shared global `AGENTS.md` (chezmoi)   | shared global `AGENTS.md` (chezmoi)   |
| Permissions   | plugin `settings.json` `permissions.allow`            | n/a (sandbox/approval in `config.toml`)     | `opencode.json` `permission.bash` (raw globs) | n/a (UI/hooks only)                  | skip (`--deny-tool` CLI flags, runtime only) |

**Shared-path strategy.** To minimize writes, the renderer leans on cross-harness shared paths:

- `.agents/skills/<name>/SKILL.md` — read by Codex, opencode, and Cursor (3 of 5).
- `.claude/agents/<name>.md` — read by Claude (via plugin re-export), opencode, and Cursor (3 of 5).

The shared file is written once. A harness-specific override file is only emitted when (a) the harness has no path in the shared coverage (Copilot for skills + agents; Claude for skills via plugin packaging; Codex for subagents via TOML) or (b) the profile pins a per-harness model for that harness (see `models:` below).

**`models:` schema.** Optional per-harness override map on subagent and slash-command items only (skills/hooks/rules have no model field on any harness). Keys are harness names (`claude`, `codex`, `opencode`, `cursor`, `copilot`); values are model identifiers. When `models.<harness>` is set, the renderer writes a harness-specific override file containing the body plus a `model:` frontmatter line — harness precedence ensures the override wins for that harness alone. Absent keys fall back to the shared file (no override). The sentinel value `inherit` (used for Cursor) means "use session model" and renders no override file.

```yaml
agents:
  - name: rust-reviewer
    body_path: agents/rust-reviewer.md
    models:                              # OPTIONAL per-harness override map
      claude: opus
      codex: gpt-5
      opencode: anthropic/claude-opus-4-7
      cursor: inherit                    # sentinel — no override file written
      # copilot key absent → Copilot ignores model field anyway
commands:
  - name: clippy
    body_path: commands/clippy.md
    models:
      claude: haiku
```

**AGENTS.md.** The per-repo profile system never edits any AGENTS.md — chezmoi owns the global `agents/AGENTS.md` and syncs it to every installed harness. Prose for all five harnesses is delivered through that shared global file, not through per-repo splicing.

**Uninstall safety:** install records every per-file artifact in `.agent-profile/manifest.json` and ref-counts shared-file entries by profile name (see `agent-profile/lib/manifest.sh`). Uninstall removes per-profile files outright and surgically removes only entries no other installed profile still references — user-added entries always survive.

**Adding a profile:** create `profiles/<name>/` with `profile.yaml` (+ payloads), or stash a per-repo override under `<repo>/.agent-profiles/<name>/`. See `agent-profile/lib/parse.sh` for schema parsing and `tests/agent-profile-*.bats` for behavioral contracts.

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
claude plugin marketplace add jarrodwatts/claude-hud
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

## Profile System

Profiles are scoped sessions at `claude/profiles/<name>/`:

- `CLAUDE.md` — profile-specific instructions (auto-discovered when `ccp <name>` launches inside it)
- `settings-merge.json` — overlay merged onto the user `settings.json` (permissions, denied tools, LSP gating)

**Existing profiles:** `fe` (frontend + shadcn/Playwright), `plugin` (plugin dev), `review` (read-only PR review), `rtkonly` (experimental — route file I/O through rtk), `spec` (discovery dialogue), `todo` (Todoist-only).

**Launch:** `ccp <name>` — loads profile dir, merges settings, scopes tool surface.
**Discover:** `ccp` with no args lists available profiles.
**Add new:** create `claude/profiles/<name>/`, drop in `CLAUDE.md` + optional `settings-merge.json`, run `dots sync`.

**Gotcha:** if your profile relies on an MCP (e.g. tilth in `rtkonly`), add `mcp__<name>__*` to the profile `settings-merge.json` allowlist — otherwise each call prompts even though the server is running.

## Sync System

The `.sync-with-rollback` script provides:

- **Automatic backups** before changes (stored in `~/.local/state/dotfiles/backups/`)
- **Manifest tracking** of all symlinks
- **Rollback capability** to any previous state
- **Per-directory .sync scripts** for custom setup (fonts, iterm2, chezmoi)

**Skip list** (not symlinked to ~, canonical source is `SYNC_SKIP_LIST` in `.sync-lib.sh`, which is sourced by `.sync-with-rollback`):

- `.git`, `.local`, `.worktrees`, `reference`, `packages`, `brew`, `apt`, `agents`, `codex`

**Hidden directory dispatch**: visible dirs are iterated by `for file in *` (glob), hidden dirs (starting with `.`) are iterated separately by `sync_hidden_dirs`. Both use the same rule: if `$dir/.sync` exists, run it. `chezmoi/` is a visible dir that owns its own `.sync` and is dispatched via the same mechanism (no SYNC_SKIP_LIST entry needed — the `.sync` short-circuit happens before symlinking).

## Chezmoi-Managed Files

A subset of dotfiles is rendered by [chezmoi](https://chezmoi.io/) instead of symlinked. Chezmoi handles per-machine templating (work vs personal git email), per-OS branching, and secret injection — things plain symlinks can't do. Everything else continues to use the symlink + `.sync` system.

`$DOTFILES` below is the absolute path to your clone of this repo (e.g. `~/Dev/dotfiles`).

**Source:** `chezmoi/` subdirectory of this repo. Currently manages:

- `~/.gitconfig` — `chezmoi/private_dot_gitconfig.tmpl` (templated email, work-only `[url]` redirects)
- `~/.copilot/mcp-config.json` — `chezmoi/private_dot_copilot/mcp-config.json.tmpl` (env-rendered API keys, fails fast if unset)
- `~/.claude/skills/`, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.codex/config.toml`, and MCP entries — handled by `run_onchange_*` scripts under `chezmoi/.chezmoiscripts/` that fork to helpers in `chezmoi/lib/`

**First-init (interactive):** `dots sync` dispatches to `chezmoi/.sync`, which invokes `chezmoi init --source $DOTFILES/chezmoi` if `~/.config/chezmoi/chezmoi.toml` is missing. The `.chezmoi.toml.tmpl` prompts for: `email`, `work`. Answers persist to `~/.config/chezmoi/chezmoi.toml` (alongside the persisted `sourceDir`) and aren't re-prompted.

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

**Adding a file:** drop a templated source under `chezmoi/` using the [chezmoi naming attributes](https://chezmoi.io/reference/source-state-attributes/) (`private_`, `dot_`, `executable_`, `encrypted_`, `.tmpl`). Reference data via `{{ .email }}`, `{{ .work }}`, etc. — see the existing templates for patterns. Add a corresponding test to `tests/chezmoi-wiring.bats`.

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

- Work email: <paul.sorensen@uber.com>
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
| MCP | `agents/mcp/registry.yaml` | `mcp-sync` (or `dots sync`) | Restart Claude / Codex / opencode / Cursor after; entries flow to all four harnesses by default. opencode entries are jq-written into `~/.config/opencode/opencode.json`; Cursor entries are jq-written into `~/.cursor/mcp.json` (`mcpServers` schema; no native CLI). |
| Hook | `agents/hooks/registry.yaml` | `hook-sync` (or `dots sync`) | Harness-agnostic SessionStart/PreTool/etc. hooks; chezmoi copies the script + lib + bank into both `~/.claude/` and `~/.codex/` then drives `agents/hooks/sync.sh` |
| Plugin (Claude) | `claude/plugins/registry.yaml` | `plugin-sync` | Add `mcp__plugin_<name>__*` to `permissions.allow` if it provides MCP tools |
| Plugin (Cursor) | `cursor/plugins/local/<name>/` (per-plugin manifest at `.cursor-plugin/plugin.json`) | `cursor-plugin-sync` (or `dots sync`) | chezmoi's `run_onchange_after_install-cursor-plugins.sh.tmpl` drives `chezmoi/lib/install-cursor-plugin.sh` per plugin, deploying to `~/.cursor/{skills,rules,commands,hooks}/` and jq-merging `hooks.json` + `modes.json`. Per-collection manifests at `<target>/.dotfiles-managed-<plugin>` track ownership. Restart Cursor after. |
| LSP | `claude/plugins/registry.yaml` (with `load: true`) | `plugin-sync` | Servers start lazily |
| Package | `packages/packages.yaml` | `dots sync` | Use `dots sync refresh` to force re-check |
| Skill | `skills/` (dirs + `_registry.yaml` for external sources) | `dots sync` (or `skill-sync` for the external-only fast path) | chezmoi's `run_onchange_after_install-claude-skills.sh.tmpl` invokes `chezmoi/lib/install-local.sh` (copies each `skills/<name>/` into `~/.claude/skills/<name>/`) and, when `gh skill` is present, `chezmoi/lib/install-external.sh` (runs `gh skill install` per harness from `SKILL_HARNESSES`). Ownership tracked via `~/.claude/skills/.dotfiles-managed`; gh-installed dirs are left untouched. |
| Profile | `profiles/<name>/profile.yaml` (or per-repo `.agent-profiles/<name>/`) | `dots profile install <name>` (per target repo) | Harness-agnostic — Claude/Codex/opencode/Cursor/Copilot rendered together; uninstall is surgical via `.agent-profile/manifest.json`. See "Agent Profiles" section above. |

## Important Gotchas

1. **Use `dots sync`**: Don't manually symlink - use the sync script for rollback support
2. **Work-Specific Config**: Git configuration includes Uber-specific settings
3. **macOS Specific**: Paths and some utilities assume macOS environment
4. **Vi Mode**: Shell is in vi mode by default
5. **MCP Scope**: Use `user` scope for dev tools, `project` for team-shared MCPs
6. **Reference Folder**: Put reference docs in `reference/` (gitignored, not symlinked)
7. **zsh Loading Order**: Files in `zsh/` are sourced in the order they appear in `zshrc`. If you add a new config file, edit `zshrc` to source it at the right point. For example, completions must load before `fzf.zsh` or keybindings might conflict.
8. **Pre-Commit Hook Failures**: If prek blocks a commit (e.g., detected secrets), fix the issue before retrying. Only use `--no-verify` for temporary overrides. Check `prek.toml` to understand what's being checked.
