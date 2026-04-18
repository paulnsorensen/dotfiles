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
| `/research` | Multi-source research: library docs, codebase analysis, prior art |

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
| `research` | Multi-source research coordinator |
| `ricotta-reducer` | Code distillation and simplification (analysis only) |
| `roquefort-wrecker` | Adversarial test writer |
| `whey-drainer` | Runs existing tests, returns concise summary |

All review/analysis agents use 0-100 confidence scoring (>= 50 to surface findings).

---

## Skills (`skills/`)

Reusable tool-usage instructions injected into agents and commands.

| Skill | Purpose |
|-------|---------|
| `diff` | Pre-commit change review |
| `fetch` | External docs via Context7, WebSearch, octocode |
| `gh` | GitHub operations via gh CLI |
| `commit` | Git staging and conventional commits |
| `tui-design` | TUI design and implementation (ratatui, Textual) |
| `worktree` | Isolated git worktree management |
| `de-slop` | AI code anti-pattern detection and fixes |
| `tdd-assertions` | Weak test assertion detection |
| `respond` | PR review comment triage with confidence scoring |
| `age` | Staff Engineer code review orchestrator (spawns 6 parallel sub-agents) |

> Code search, file discovery, reading, editing, and blast-radius analysis go through the `tilth` MCP (`tilth_search`, `tilth_files`, `tilth_read`, `tilth_edit`, `tilth_deps`) — not a dedicated skill.

---

## Hooks (`hooks/`)

### Pre-Tool Hooks (JavaScript)

**block-install.js** -- Requires human approval for package installations. Triggers on `npm install`, `yarn add`, `pnpm add`, `pip install`, `go get`, `cargo add`.

**phantom-file-check.js** -- Prevents reading non-existent files (anti-hallucination). Checks `fs.existsSync()` before allowing Read tool calls.

### Lifecycle Hooks (Shell)

| Hook | Event | Purpose |
|------|-------|---------|
| `pre-compact.sh` | PreCompact | Saves session context before compaction |
| `post-compact.sh` | SessionStart (compact) | Restores context after compaction |
| `post-fresh-start.sh` | SessionStart | Injects tilth MCP usage reminder on fresh sessions |
| `on-session-end.sh` | UserPromptSubmit | Detects parting language, suggests saving context |

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

**LSP Plugins** (from `boostvolt/claude-code-lsps`):

| Plugin | Language |
|--------|----------|
| `pyright` | Python |
| `gopls` | Go |
| `rust-analyzer` | Rust |
| `vtsls` | TypeScript/JS |
| `solargraph` | Ruby |
| `bash-language-server` | Bash |
| `yaml-language-server` | YAML |

**Workflow Plugins** (from `anthropics/claude-code-plugins`):

| Plugin | Purpose |
|--------|---------|
| `code-simplifier` | Code cleanup and simplification |
| `hookify` | Create hooks from conversation analysis |
| `claude-md-management` | CLAUDE.md audit and maintenance |
| `playwright` | Browser testing and automation |
| `ralph-loop` | Iterative convergent loops |
| `frontend-design` | UI/UX implementation |
| `skill-creator` | Guided skill creation |

---

## MCP Servers

Managed declaratively via `mcp/registry.yaml`. Sync with `mcp-sync`.

| MCP | Purpose |
|-----|---------|
| `octocode` | GitHub code search and repository tools |
| `context7` | Documentation context for libraries and frameworks |

---

## Core Engineering Principles

All agents enforce these principles:

1. **Input Validation** -- Trust nothing from external sources
2. **Fail Fast and Loud** -- Handle errors where they occur
3. **Loose Coupling** -- Separate business logic from infrastructure
4. **YAGNI** -- Build only what's needed now
5. **Real-World Models** -- Name after business concepts
6. **Immutable Patterns** -- Minimize state mutation
