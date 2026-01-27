# CLAUDE.md - Claude Code Configuration

This directory contains the complete Claude Code configuration for the Cheddar Flow development workflow.

## Setup

Run the setup script to symlink everything to `~/.claude/`:
```bash
./setup.sh
```

This creates:
- `~/.claude/agents/` -> symlink to `agents/`
- `~/.claude/commands/` -> symlink to `commands/`
- `~/.claude/hooks/` -> symlink to `hooks/`
- Copies `settings.json` to `~/Library/Application Support/claude-code/`
- Copies `memories/*.md` to `~/.serena/memories/`

## Directory Structure

```
claude/
├── agents/           # Cheese-themed specialist agents
├── commands/         # Slash commands (/cheese, /curdle, etc.)
├── hooks/            # Pre-tool enforcement hooks
├── memories/         # Serena persistent context (templates)
├── settings.json     # Plugin configuration
├── setup.sh          # Installation script
└── CLAUDE.md         # This file
```

---

## Commands (`commands/`)

Slash commands invoked with `/command-name`.

### Workflow Commands

| Command | Description |
|---------|-------------|
| `/cheese` | Quick 4-step workflow: Explore → Plan → Code → Light Review |
| `/curdle` | Full 6-step workflow: Explore → Plan → Code → Test → Review → Commit |

### Learning Commands

| Command | Description | Use Case |
|---------|-------------|----------|
| `/pingpong` | TDD pairing - AI writes tests, you implement | Learning TDD, building muscle memory |
| `/duck` | Rubber duck problem-solving | Clarifying requirements before coding |
| `/hint` | Progressive hints (3 levels) | When stuck but want to learn |
| `/review` | Teaching-focused code review | Understanding why, not just what |
| `/explain` | Concept explanation with quizzes | Deep understanding of patterns |

### Command Anatomy

```markdown
---
name: command-name
description: Shown in /help
allowed-tools: Read, Write, Bash  # Optional tool restrictions
argument-hint: [what args look like]
---

Command prompt content here.
Use $ARGUMENTS for user input.
Use {{request}} for template substitution.
```

---

## Agents (`agents/`)

Specialized agents for each workflow stage. Invoked via Task tool with `subagent_type`.

| Agent | Stage | Purpose | Model |
|-------|-------|---------|-------|
| `gouda-explorer` | Explore | Read-only codebase mapping with Serena | sonnet |
| `brie-architect` | Plan | Implementation strategy, hexagonal design | - |
| `cheddar-craftsman` | Code | YAGNI-focused implementation | - |
| `roquefort-wrecker` | Test | Adversarial testing (invalid inputs first) | - |
| `parmigiano-sentinel` | Review | Principle enforcement gate | - |
| `manchego-chronicler` | Commit | Conventional Commits with context | - |

### Agent File Format

```markdown
---
name: agent-name
description: When to use this agent (shown in Task tool)
tools: tool1, tool2, tool3  # Allowed tools
model: sonnet               # Optional model override
color: yellow               # Terminal color
---

System prompt content here.
```

### Key Agent Behaviors

**gouda-explorer**:
- MUST call `activate_project` first for Serena
- Read-only - never modifies files
- Uses `find_symbol`, `find_referencing_symbols`, `get_symbols_overview`
- 95% confidence rule - asks questions when uncertain

**roquefort-wrecker**:
- Tests invalid inputs BEFORE happy paths
- Assumes code is guilty until proven innocent
- Focuses on edge cases and error handling

**parmigiano-sentinel**:
- Enforces all 6 core engineering principles
- Final quality gate - no code passes without approval
- Can reject changes that violate principles

---

## Hooks (`hooks/`)

JavaScript hooks that intercept tool calls. Run before tools execute.

### block-install.js

**Purpose**: Requires human approval for package installations

**Triggers on**:
- `npm install`, `yarn add`, `pnpm add`
- `pip install`, `pip3 install`
- `go get`, `cargo add`

**Behavior**: Blocks the command and asks user to:
1. Confirm stdlib can't solve the problem
2. Review dependency weight
3. Explicitly approve

### phantom-file-check.js

**Purpose**: Prevents reading non-existent files (anti-hallucination)

**Triggers on**: `Read` tool calls

**Behavior**: Checks `fs.existsSync()` before allowing read. Returns error message if file doesn't exist.

### Hook Format

```javascript
module.exports = {
  event: 'preToolUse',  // or 'postToolUse'
  hooks: [{
    matcher: (toolName, input) => boolean,
    handler: async (input) => {
      // Return { result: "message" } to block
      // Return null to allow
    }
  }]
};
```

---

## Settings (`settings.json`)

Configures plugins and preferences. Copied to `~/Library/Application Support/claude-code/`.

### Plugin Marketplaces

```json
{
  "extraKnownMarketplaces": {
    "claude-code-lsps": {
      "source": { "source": "github", "repo": "boostvolt/claude-code-lsps" }
    },
    "claude-plugins-official": {
      "source": { "source": "github", "repo": "anthropics/claude-code-plugins" }
    }
  }
}
```

### Enabled Plugins

**LSP Plugins** (from `boostvolt/claude-code-lsps`):
| Plugin | Language | Purpose |
|--------|----------|---------|
| `pyright` | Python | Type checking, intellisense |
| `gopls` | Go | Go language server |
| `rust-analyzer` | Rust | Rust language server |
| `vtsls` | TypeScript/JS | TypeScript language server |

**Workflow Plugins** (from `anthropics/claude-code-plugins`):
| Plugin | Purpose |
|--------|---------|
| `pr-review-toolkit` | PR review with specialized agents |
| `commit-commands` | Git commit helpers |
| `security-guidance` | Security best practices |
| `code-simplifier` | Code cleanup and simplification |

### Other Settings

```json
{
  "model": "claude-opus-4-20250514",
  "editor": "vim",
  "tools": { "web_search": { "enabled": true } },
  "formatting": {
    "code_style": { "indent_size": 2, "use_spaces": true, "max_line_length": 100 }
  },
  "integrations": {
    "git": { "commit_style": "conventional" }
  }
}
```

---

## Memories (`memories/`)

Template files for Serena's persistent memory. Copied to `~/.serena/memories/`.

| Memory | Purpose |
|--------|---------|
| `architecture.md` | Project structure and design decisions |
| `coding-standards.md` | Style guide, naming conventions, complexity budget |
| `current-plan.md` | Active workflow plan state |
| `dependency-analysis.md` | Symbol reference analysis results |

These are templates - Serena updates them during workflows.

---

## Core Engineering Principles

All agents enforce these principles:

1. **Input Validation** - Trust nothing from external sources
2. **Fail Fast and Loud** - Handle errors where they occur
3. **Loose Coupling** - Separate business logic from infrastructure
4. **YAGNI** - Build only what's needed now
5. **Real-World Models** - Name after business concepts
6. **Immutable Patterns** - Minimize state mutation

---

## Quick Reference

```bash
# Workflows
/cheese "fix login bug"           # Quick 4-step
/curdle "add user auth"           # Full 6-step

# Learning
/pingpong "user validation"       # TDD pairing
/duck "how to structure caching?" # Think before code
/hint "why is async failing?"     # Get hints, not answers
/review src/auth.ts               # Teaching review
/explain "dependency injection"   # Learn concepts

# Direct agent access (via Task tool)
gouda-explorer    # Explore codebase
brie-architect    # Plan implementation
cheddar-craftsman # Write code
roquefort-wrecker # Break code with tests
parmigiano-sentinel # Review for principles
manchego-chronicler # Craft commit messages
```

---

*"May your code be strong, your bugs few, and your workflow truly brie-lliant."*
