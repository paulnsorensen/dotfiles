# Claude Code Configuration

This directory contains the complete Claude Code configuration for the Cheddar Flow development workflow.

## Setup

Symlinked to `~/.claude/` via the dotfiles sync system:

```bash
dots sync
```

This creates symlinks for `agents/`, `commands/`, `hooks/`, `skills/`, `settings.json`, and `mcp/`.

## Directory Structure

```
claude/
├── agents/           # Specialist agents (Fromage pipeline + standalone)
├── commands/         # Slash commands (/fromage, /spec, /age, etc.)
├── hooks/            # Pre-tool enforcement hooks + lifecycle hooks
├── mcp/              # MCP registry and sync script
│   ├── registry.yaml # Source of truth for MCP servers
│   └── sync.sh       # Declarative sync via native claude mcp commands
├── plugins/          # Plugin registry and sync script
│   ├── registry.yaml # Source of truth for plugins
│   └── sync.sh       # Declarative sync via native claude plugin commands
├── skills/           # Reusable tool-usage instructions for agents
├── settings.json     # Claude Code settings (env, permissions, hooks, plugins)
├── .sync             # Sync script for dotfiles integration
├── .gitignore        # Excludes local state
├── CLAUDE.md         # Project instructions (this is separate from this README)
└── README.md         # This file
```

---

## Commands (`commands/`)

Slash commands invoked with `/command-name`.

### Workflow Commands

| Command | Description |
|---------|-------------|
| `/fromage` | Intelligent cheese-making pipeline (Preparing -> Pasteurize -> Culture -> Curdle -> Cut -> Cook -> Press -> Age -> Package) |
| `/spec` | Discovery dialogue to architect a feature and produce a specification |
| `/scaffold` | Scaffold a new domain slice following Sliced Bread architecture |
| `/worktree` | Create an isolated git worktree for a task |

### Review & Quality Commands

| Command | Use When |
|---------|----------|
| `/diff` | Pre-commit smoke test -- catch secrets, debug statements, silent failures |
| `/age` | Staff Engineer code review of recent changes (fromage-age, focused mode) |
| `/code-review` | Deep dive -- full architectural walkthrough with persistent history |
| `/simplifier` | Reduction -- strip genAI bloat, enforce YAGNI (invokes ricotta-reducer) |
| `/copilot-review` | PR review -- analyze, present findings, route fixes to Copilot |
| `/copilot-delegate` | Delegate PR fixes to GitHub Copilot via inline comments |
| `/copilot-setup` | Generate GitHub Copilot agent and review instructions for a repo |
| `/audit` | Security and dependency health audit (fromage-pasteurize) |
| `/wreck` | Adversarial test writer (roquefort-wrecker) |
| `/test` | Run existing tests via whey-drainer, returns concise summary |

### Utility Commands

| Command | Description |
|---------|-------------|
| `/agents` | Control panel listing all agents, skills, and commands |
| `/setup-perms` | Scaffold `.claude/settings.local.json` with project permissions |
| `/onboard` | Quick codebase orientation for an unfamiliar repo |
| `/pull` | Pull latest from main |
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

### Fromage Pipeline Agents

| Agent | Phase | Purpose |
|-------|-------|---------|
| `fromage-pasteurize` | Pasteurize | Security and dependency health audit |
| `fromage-culture` | Culture | Read-only codebase exploration |
| `fromage-curdle` | Curdle | Execution plan creation (plan mode) |
| `fromage-cook` | Cook | Implementation |
| `fromage-press` | Press | Adversarial testing |
| `fromage-age-safety` | Age | Correctness & safety (bugs, security, silent failures) |
| `fromage-age-arch` | Age | Complexity budgets, nesting smells, file structure |
| `fromage-age-encap` | Age | Encapsulation, leaky abstractions, boundary violations |
| `fromage-age-yagni` | Age | Dead code (must be justified), speculative abstractions, AI noise |
| `fromage-age-history` | Age | Git history risk signals → per-file score modifiers |
| `fromage-age-spec` | Age | Spec drift, monkey patches, missing implementations |

> **Note**: The `age` orchestration is a **skill** (`skills/age/SKILL.md`), not an agent. It runs inline in the caller's context and spawns the 6 sub-agents as first-level agents — no nested agent depth issues.

### Standalone Agents

| Agent | Purpose |
|-------|---------|
| `cheese-factory` | Codebase orientation and mapping |
| `ricotta-reducer` | Code distillation and simplification (analysis only) |
| `roquefort-wrecker` | Adversarial test writer |
| `whey-drainer` | Runs existing tests, returns concise summary |

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
| `diff` | Pre-commit change review |
| `fetch` | External docs via Context7, WebSearch, Tavily |
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
| `bash-guard.js` | Bash | Blocks dangerous shell patterns before execution |
| `write-guard.js` | Write | Blocks writes to disallowed paths |
| `phantom-file-check.js` | Read | Prevents reading non-existent files (anti-hallucination) |
| `review-reply-guard.js` | GitHub PR reply MCPs | Catches deferral language in PR review replies |

### Post-Tool Hooks

| Hook | Tool match | Purpose |
|------|-----------|---------|
| `auto-format.js` | Edit, Write | Runs project formatter on edited files |

### Lifecycle Hooks (Shell)

| Hook | Event | Purpose |
|------|-------|---------|
| `pre-compact.sh` | PreCompact | Saves session context before compaction |
| `post-compact.sh` | SessionStart (compact) | Restores context after compaction |
| `post-fresh-start.sh` | SessionStart | Injects `cheese-flow:cheez-search` suggestion on fresh sessions |
| `on-session-end.sh` | UserPromptSubmit | Detects parting language, suggests saving context |
| Stop guard (inline agent) | Stop | Catches hesitation around commit/push/PR creation |
| `rtk hook claude` | PreToolUse Bash | Token-optimizing command rewriter |

### Hookify Rules (`hookify/`)

Managed hookify rules synced to `~/.claude/` by `claude/.sync`. These fire automatically — no skill invocation needed.

| Rule | Event | Action | What it catches |
|------|-------|--------|-----------------|
| `warn-deferred-stop` | stop | warn | Deferred work at session end (for now, out of scope, would need to) |
| `warn-placeholder-code` | file | warn | TODO/FIXME/`unimplemented!()` in written code |
| `warn-ellipsis-code` | file | warn | `// ...` and "rest is similar" hand-waves |

Add new rules to `claude/hookify/` as `hookify.<name>.local.md` files. Run `dots sync` to symlink them to `~/.claude/`.

---

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

**LSP Plugins** (from `boostvolt/claude-code-lsps`, lazy-start per file type):

| Plugin | Language |
|--------|----------|
| `bash-language-server` | Bash/shell |
| `vtsls` | TypeScript/JavaScript |
| `yaml-language-server` | YAML |
| `rust-analyzer` | Rust |
| `pyright` | Python |
| `gopls` | Go |

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

Managed declaratively via `mcp/registry.yaml`. Sync with `mcp-sync` (run `mcp-ls` to verify).

User-scope MCPs (registered here):

| MCP | Purpose |
|-----|---------|
| `code-review-graph` | Persistent code knowledge graph; impact radius, call chains, architectural framing |
| `serper` | Google SERP for factual lookups |
| `todoist` | Todoist task/project management |

Plugin-provided MCPs (declared by `cheese-flow`'s `.mcp.json`, session-wide and accessible to all skills):

| MCP | Provider | Purpose |
|-----|----------|---------|
| `context7` | cheese-flow | Library/framework docs (React, Tailwind, Next.js, …) |
| `tavily` | cheese-flow | AI-powered technical research |
| `tilth` | cheese-flow | AST-aware code search/read; backs `cheez-*` skills |
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
