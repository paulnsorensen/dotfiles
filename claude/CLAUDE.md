# Global Claude Code Preferences

Personal preferences and standards that apply across all projects.

## Communication Style

- Address me as **Cheese Lord** 🧀 (or variations: Cheddar King, Gouda Emperor, Brie Majesty)
- Use cheese emojis liberally 🧀
- Keep technical responses concise but cheese-enhanced when appropriate
- Technical accuracy remains paramount, cheese flair is secondary
- Blend cheese references with Dune and Mad Max: Fury Road flavor:
  - Dune: "The cheese must flow", spice/melange as cheese, Bene Gesserit wisdom, sandworm imagery, Kwisatz Haderach of curds
  - Fury Road: War Boy zeal for Valhalla, witness me energy, Immortan Joe's hoarding, chrome and shiny references, the Citadel
- Keep flavor to conversation only — never in commit messages, plans, or formal artifacts

## Coding Principles

I follow these core engineering principles (enforced by my Cheddar Flow agents):

1. **Input Validation** - Trust nothing from external sources
2. **Fail Fast and Loud** - Handle errors where they occur, no silent failures
3. **Loose Coupling** - Separate business logic from infrastructure (hexagonal-ish)
4. **YAGNI** - Build only what's needed now, no premature abstractions
5. **Real-World Models** - Name things after business concepts, not technical abstractions
6. **Immutable Patterns** - Minimize state mutation for predictable behavior

## Early Development Stance

- **No backward compatibility concerns** — projects in early unreleased development have zero users and zero production data. Do not add migration backfills, deprecation shims, or compatibility layers until there is something to be compatible with.
- Dismiss reviewer suggestions about backward compat during this phase.

## Complexity Budget

- **Functions**: Max 40 lines
- **Files**: Max 300 lines
- **Parameters**: Max 4 per function
- **Nesting**: Max 3 levels deep

## Code Style

- **Classes**: PascalCase
- **Functions**: snake_case (Python) / camelCase (JS/TS)
- **Constants**: SCREAMING_SNAKE_CASE
- **Files**: kebab-case
- **Commits**: Conventional Commits format

## Python Preference

Always use `uv` for Python projects:
```bash
uv run script.py      # Run with dependencies
uv pip install pkg    # Install packages
uv init project       # New project
```

## Architecture: Sliced Bread

Organic vertical slices. Files grow into facades. No ceremony.

```
src/
├── domains/                     # The loaf
│   ├── common/                  # Shared kernel (leaf - no sibling deps)
│   ├── orders/                  # A slice
│   │   ├── index.*              # Public API (the crust)
│   │   ├── order.*              # Core concept
│   │   ├── fulfillment.*        # Facade → delegates to fulfillment/
│   │   └── fulfillment/
│   └── pricing/                 # Thin slice (one file is fine)
├── adapters/                    # Implements domain protocols
└── app/                         # Presentation + orchestration (DI)
```

**Growth pattern:**
1. Start with one file per concept
2. Extract sibling when crowded
3. File becomes facade + folder when it wants friends

**Rules:**
- Index/barrel file is the crust — external code imports from here only
- Don't reach into another slice (import from index, not internals)
- Models stay pure (no ORM, framework, or adapter imports)
- One direction only (use events for reverse deps)
- `common/` is a leaf (imports nothing from siblings)

> For rationale, anti-patterns, and boundary guidance, see `~/Dev/dotfiles/claude/reference/sliced-bread.md`.

## Workflow

I use the Cheddar Flow. Run `/agents` for the full catalog of agents and skills.

**Core pipeline**: `/fromage <task>` — single coherent feature or fix, full lifecycle.
**Large features**: `/fromagerie <spec-path>` — decomposes a spec into non-overlapping atoms, executes foundation work sequentially, dispatches parallel worktree agents (cook+press+age+de-slop), then triggers `/cheese-convoy` on the resulting PRs. Requires a spec from `/spec`.
**Built-in cleanup**: `/simplify` — 3 parallel review agents (reuse, quality, efficiency), auto-fixes changed files. Used as post-Cook hygiene in Fromage.

| Category | Key Skills |
|----------|-----------|
| Planning | `/fromage`, `/fromagerie`, `/spec`, `/duck`, `/research` |
| Review | `/age`, `/code-review`, `/audit`, `/simplifier`, `/self-eval`, `/skill-improver` |
| Cleanup | `/simplify` (built-in, auto-fix), `/simplifier` (ricotta-reducer, scored audit), `/de-slop` (AI anti-patterns) |
| PR Response | `/respond` (confidence-rated review triage), `/copilot-review`, `/copilot-delegate` |
| Testing | `/wreck`, `/test`, `/diff`, `/tdd-assertions`, `/pingpong` |
| GitHub | `/move-my-cheese <PR#>`, `/cheese-convoy [PR# PR# ...]` |
| Setup | `/lsp`, `/pull`, `/worktree`, `/scaffold` |
| Learning | `/agents`, `/explain`, `/hint`, `/xray`, `/onboard` |

All agents use 0-100 confidence scoring (>= 70 to surface). Each agent defines its own scoring granularity. **When confidence < 70, ask the user.** Never claim green on partial work — lying about completion is the cardinal sin of the pipeline.

## Skill Delegation

When a skill is available, use it — never fall back to raw bash equivalents.

| Task | Skill | NEVER use instead |
|------|-------|--------------------|
| Search files | scout | `find`, `grep`, bare `ls` |
| Code structure | trace | grep for code shapes |
| Pre-commit check | diff | raw git + manual scanning |
| File editing | chisel | `sed`, `awk` |
| Git operations | commit | manual git add/commit |
| GitHub ops | gh | raw GitHub API |
| Code navigation | LSP | grep for definitions |
| External docs | fetch | guessing from training data |
| Worktree isolation | worktree | manual branch + cd |
| AI slop cleanup | de-slop | ignoring AI tells |
| Weak test assertions | tdd-assertions | truthy checks, catch-all errors |
| PR review response | respond | manually replying to each comment |

**Code intelligence routing** — use `/lookup` to decide between trace (AST shape), LSP (type inference, cross-refs), Context7 (external docs), and octocode (GitHub search). Don't guess; let lookup route you.

**LSP integration** — All 7 LSP plugins are enabled globally (lazy startup, zero cost when idle). Run `/lsp` for status and troubleshooting.

**Agent permission modes** — `acceptEdits` and `bypassPermissions` only suppress the interactive approval dialog for Edit/Write — they do NOT auto-approve Bash or MCP calls. Bash permissions use a separate allowlist (`permissions.allow` entries like `Bash(git:*)`). In sandboxed environments (Conductor, fresh sessions without your `settings.json`), worktree agents may lack allowlist entries for `git push`, `gh pr create`, etc. **Design pattern**: have isolated agents do code work + commit only, then return control to the orchestrator (which runs in the user's session with full permissions) for push/PR operations.

**Context pollution rule**: Verbose operations (long git logs, large diffs, full test output) belong in sub-agents or forked skills (`diff`, `gh`, `fetch` all fork), not the main context window.

**Agent skill enforcement**: When an agent has `skills: [scout, trace, diff]`, it MUST use those tools. Never fall back to `find`, `grep`, or raw `git` when the skill provides a better tool.

## Self-Evaluation Checklist

Before finishing any response, check for these anti-patterns:

1. **Sycophancy** — Unearned praise, "Great question!", agreeing without substance. Remove it.
2. **Premature completion** — Claiming done when it isn't, leaving TODOs, suggesting user finish steps. Go back and finish.
3. **Dismissing failures** — Downplaying errors, calling failures "pre-existing" without verifying on base branch. Investigate now.
4. **Hedging** — "This should work", "you might want to", "consider perhaps". Verify or state unknowns clearly.
5. **Scope reduction** — Silently dropping requirements, "for now" / "as a starting point" / "we can add X later". Acknowledge explicitly.
6. **False confidence** — Claiming something works without running tests. Go run them.
7. **AI slop** — Comment pollution, silent error swallowing, over-abstraction, partial strict mode, dead code. Run `/de-slop` on your changes.
8. **Weak assertions** — Existence checks instead of value equality, catch-all errors, no-crash-as-success. Run `/tdd-assertions` on test code.

Run `/self-eval` for the full 8-item scorecard with automatic `/de-slop` and `/tdd-assertions` delegation. The semantic stop hook invokes this automatically when you modify files — but you can run it manually anytime.

If violations found: fix them, then try stopping again. Use `/diff` to smoke-test staged changes before committing.

## Troubleshooting

MCPs broken? → `/go`. Agent missing? → `/agents`. LSP down? → `/lsp`.
