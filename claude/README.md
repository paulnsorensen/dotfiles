# Claude Code Configuration

This directory contains the complete Claude Code configuration for the Cheddar Flow development workflow.

## Setup

Symlinked to `~/.claude/` via the dotfiles sync system:

```bash
dots sync
```

This creates symlinks for `agents/`, `commands/`, `hooks/`, `skills/`, and `settings.json`. The shared MCP registry now lives at the repo-root `agents/mcp/` (copied to both Claude and Codex by chezmoi).

## Directory Structure

```
claude/
├── agents/           # Specialist agents (Fromage pipeline + standalone)
├── commands/         # Slash commands (/spec, /wreck, /test, etc.)
├── hooks/            # Pre-tool enforcement hooks + lifecycle hooks
├── lib/              # Shared sync helpers (sync-common.sh, gen-profile-mcp.sh)
├── plugins/          # Plugin registry and sync script
│   ├── registry.yaml # Source of truth for plugins
│   └── sync.sh       # Declarative sync via native claude plugin commands
├── skills/           # Reusable tool-usage instructions for agents
├── settings.json     # Claude Code settings (env, permissions, hooks, plugins)
├── .sync             # Sync script for dotfiles integration
├── .gitignore        # Excludes local state
└── README.md         # This file
```

> The shared global agent instructions live at `agents/AGENTS.md` (repo root) and are copied to `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` by chezmoi. The MCP registry lives at `agents/mcp/registry.yaml` and is applied to both harnesses by `agents/mcp/sync.sh`.

---

## Commands (`commands/`)

Slash commands invoked with `/command-name`.

### Workflow Commands

| Command | Description |
|---------|-------------|
| `/spec` | Discovery dialogue to architect a feature and produce a specification |
| `/scaffold` | Scaffold a new domain slice following Sliced Bread architecture |

### Review & Quality Commands

| Command | Use When |
|---------|----------|
| `/copilot-review` | PR review -- analyze, present findings, route fixes to Copilot |
| `/copilot-delegate` | Delegate PR fixes to GitHub Copilot via inline comments |
| `/copilot-setup` | Generate GitHub Copilot agent and review instructions for a repo |
| `/wreck` | Adversarial test writer (roquefort-wrecker) |
| `/test` | Run existing tests via whey-drainer, returns concise summary |

### Utility Commands

| Command | Description |
|---------|-------------|
| `/setup-perms` | Scaffold `.claude/settings.local.json` with project permissions |
| `/briesearch` | Multi-source research: library docs, codebase analysis, prior art (cheese-flow plugin) |

### Learning Commands

| Command | Description |
|---------|-------------|
| `/pingpong` | TDD pairing -- AI writes tests, you implement |
| `/duck` | Rubber duck problem-solving |
| `/hint` | Progressive hints (3 levels) |
| `/explain` | Concept explanation with quizzes |

---

## Agents (`agents/`)

Specialized agents invoked via Task tool with `subagent_type`.

### Review & Test Agents

| Agent | Purpose |
|-------|---------|
| `fromage-pasteurize` | Security and dependency health audit (invoked by `/copilot-review`) |
| `fromage-fort` | PR review comment responder with confidence scoring |
| `fromage-age-arch` | Complexity budgets, nesting smells, file structure |
| `fromage-age-history` | Git history risk signals → per-file score modifiers |
| `ricotta-reducer` | Code distillation and simplification (analysis only) |
| `roquefort-wrecker` | Adversarial test writer |
| `whey-drainer` | Runs existing tests, returns concise summary |
| `nih-scanner` | Structural NIH pattern scanner |
| `worktree-triage` | Stale-worktree triage recommendations |

All review/analysis agents use 0-100 confidence scoring (>= 50 to surface findings).

---

## Skills (`skills/`)

Reusable tool-usage instructions injected into agents and commands.

| Skill | Purpose |
|-------|---------|
| `scout` | Directory listings (eza); delegates code search to `cheese-flow:cheez-search` |
| `cheese-flow:cheez-search` | AST-aware code/content search via tilth MCP (replaces trace) |
| `cheese-flow:cheez-read` | Hash-anchored code reading via tilth MCP |
| `cheese-flow:cheez-write` | Hash-anchored code editing via tilth MCP (replaces chisel) |
| `gh` | GitHub operations via gh CLI |
| `commit` | Git staging and conventional commits |
| `tui-design` | TUI design and implementation (ratatui, Textual) |
| `worktree` | Isolated git worktree management |
| `de-slop` | AI code anti-pattern detection and fixes |
| `tdd-assertions` | Weak test assertion detection |
| `respond` | PR review comment triage with confidence scoring |
| `age` | Staff Engineer code review orchestrator (spawns 6 parallel sub-agents) |

---

## Hooks (`hooks/`)

Source of truth: the `hooks` block in `claude/settings.json` (run `dots sync` to apply changes).

### Pre-Tool Hooks (JavaScript)

| Hook | Tool match | Purpose |
|------|-----------|---------|
| `write-guard.js` | Edit, Write | Blocks placeholder/lazy code and inline test snippets |
| `worktree-guard.js` | _(disabled)_ | File kept in tree for reference; not registered in settings |
| `phantom-file-check.js` | Read | Prevents reading non-existent files (anti-hallucination) |

### Post-Tool Hooks

| Hook | Tool match | Purpose |
|------|-----------|---------|
| `auto-format.js` | Edit, Write | Runs project formatter on edited files |

### Other

| Hook | Event | Purpose |
|------|-------|---------|
| `rtk hook claude` | PreToolUse Bash | Token-optimizing command rewriter |

## Settings (`settings.json`)

```json
{
  "env": { ... },            // Feature flags (agent teams, tool search)
  "permissions": { ... },    // Auto-allowed tools (git, MCPs, web)
  "hooks": { ... },          // Lifecycle hook definitions
  "enabledPlugins": { ... }  // Plugin enable/disable state
}
```

### Enabled Plugins

Source of truth: `claude/plugins/registry.yaml` (run `plugin-ls` to verify).

Symbol-level code intelligence is provided by the Serena MCP (see
`agents/mcp/registry.yaml`); the per-language LSP plugins from
`boostvolt/claude-code-lsps` were removed once Serena went cross-harness.

**Workflow Plugins** (from `anthropics/claude-code-plugins`):

| Plugin | Purpose |
|--------|---------|
| `claude-md-management` | CLAUDE.md audit and maintenance |
| `playwright` | Browser testing and automation |
| `frontend-design` | UI/UX implementation |
| `plugin-dev` | Plugin development toolkit |
| `skill-creator` | Guided skill creation |

**Other Marketplaces**:

| Plugin | Source | Purpose |
|--------|--------|---------|
| `claude-hud` | `jarrodwatts/claude-hud` | Statusline HUD |
| `cheese-flow` | local (`~/Dev/cheese-flow`) | Cheddar Flow agent pipeline + tilth MCP + cheez-* skills |
| `todoist-flow` | in-repo (`claude/plugins/local/todoist-flow`) | Todoist productivity suite |
| `vaudeville` | local (`~/Dev/vaudeville`) | SLM-powered semantic hook enforcement |

---

## MCP Servers

Managed declaratively via the shared registry at `agents/mcp/registry.yaml` (driven by `agents/mcp/sync.sh`). Sync with `mcp-sync` (run `mcp-ls` to verify). Entries default to both harnesses; set `harnesses: [claude]` or `[codex]` to target one.

User-scope MCPs (registered here):

| MCP | Purpose |
|-----|---------|
| `code-review-graph` | Persistent code knowledge graph; impact radius, call chains, architectural framing |
| `serper` | Google SERP for factual lookups |
| `todoist` | Todoist task/project management |
| `tilth` | AST-aware code search/read/edit (Tree-sitter); backs `cheez-*` skills. Gated by `gate_unless: CHEESE_FLOW` — installed only when the cheese-flow plugin is dark, since the plugin bundles its own tilth MCP |

Plugin-provided MCPs (declared by `cheese-flow`'s `.mcp.json` when `CHEESE_FLOW=true`, session-wide and accessible to all skills):

| MCP | Provider | Purpose |
|-----|----------|---------|
| `context7` | cheese-flow | Library/framework docs (React, Tailwind, Next.js, …) |
| `tavily` | cheese-flow | AI-powered technical research |
| `tilth` | cheese-flow | AST-aware code search/read; backs `cheez-*` skills (supersedes the registry entry above when active) |
| `milknado` | cheese-flow | Mikado-method change graph for `milknado-*` skills |

Profile-only MCPs (loaded per-profile via `--mcp-config`, not registry-managed):

| MCP | Profile | Purpose |
|-----|---------|---------|
| `shadcn` | `fe` | Component registry for frontend work |

---

## Core Engineering Principles

All agents enforce these principles:

1. **Input Validation** -- Trust nothing from external sources
2. **Fail Fast and Loud** -- Handle errors where they occur
3. **Loose Coupling** -- Separate business logic from infrastructure
4. **YAGNI** -- Build only what's needed now
5. **Real-World Models** -- Name after business concepts
6. **Immutable Patterns** -- Minimize state mutation
