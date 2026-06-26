# cheese-grok

A Cursor plugin for **grokking unfamiliar codebases** and **authoring
slop-free design docs**. Bundled with reader-first guardrails so the
AI critiques rather than authors.

## What's in the box

| Primitive | What it does |
|---|---|
| **`/grok-codebase`** (skill) | Maps a repo using the four-pillar model — Building Blocks → Entry Points → Infrastructure → Egress — then runs an adaptive Socratic quiz to lock it into long-term understanding. Multi-session, ≤30k tokens. |
| **`/tour`** (skill) | Single-session sibling of `/grok-codebase`. Layered summary (project purpose → module map → call graph for the pointed-at thing) with file:line citations. Anchors on entry points; stops after answering. ≤10k tokens. |
| **`/design-doc`** (skill) | Drives a spine-first authoring workflow where you write Context / Problem / Goals / Non-Goals / Alternatives / Risks; the AI is restricted to critique, expansion, and copyedit. |
| **`/read-mode-probe`** (skill) | Five probes (invariant, data-flow, error-path, hot-path, security) that return numbered findings with confidence + citations, never edits. |
| `reader-companion.mdc` (rule) | Always-on reader-first stance with file:line citation requirement and banned-phrase list. |
| `reader` (custom mode) | Locks edits, allows symbol/search/MCP-read tools, prepends a reader-first system prompt. |
| `/reading-probes`, `/hostile-editor`, `/tighten`, `/mental-model` (commands) | Quick paste-in prompts for common reader/critic flows. |
| `hooks.json` | Blocks destructive shell commands; appends a one-line session-end audit log. |

## Install (via dotfiles)

This plugin is installed automatically by `dots sync` (chezmoi's
`run_onchange_after_install-cursor-plugins.sh.tmpl` deploys it into your
`~/.cursor/` auto-discovery directories).

To verify after `dots sync`:

```bash
ls ~/.cursor/skills/        # grok-codebase, design-doc, read-mode-probe
ls ~/.cursor/rules/         # reader-companion.mdc
ls ~/.cursor/commands/      # reading-probes.md, hostile-editor.md, tighten.md, mental-model.md
jq '.modes | keys' ~/.cursor/modes.json    # includes "reader"
jq '.hooks | keys' ~/.cursor/hooks.json    # includes beforeShellExecution, stop
```

Required MCPs (Serena, tilth, code-review-graph, Context7) are
deployed by `mcp-sync` (or `dots sync`) into `~/.cursor/mcp.json`.

## Trigger phrases

- **Grok (deep, multi-session):** "grok this repo", "onboard me",
  "memorize this project", "lock this codebase into memory",
  "quiz me on this repo", "help me understand this codebase deeply".
- **Tour (lightweight, single session):** "tour this repo", "give me
  a tour", "what does this project do", "trace how X works", "where
  is Y implemented", "show me how this works".
- **Design doc:** "draft a design doc", "RFC for X", "ADR for Y",
  "tech spec", "review my design doc", "tighten this draft".
- **Probe:** "probe this", "what are the invariants here", "where
  does X flow", "find risks in this code", "security audit this file".

## Reader mode

Cycle Shift+Tab in the Cursor agent input until "reader" appears in
the mode list, or pick it from the modes dropdown. It locks
`edit_file` / `write_file` / `mcp__tilth__tilth_write` and only allows
read-only shell commands (`git log|status|diff|show|blame`, `ls`,
`wc`, `cat`, `head`, `tail`, `tokei`, `jq`, `yq`, `fd`, `rg`, `tree`,
`file`, `stat`).

## Source of truth

This plugin lives at `cursor/plugins/local/cheese-grok/` in
[paulnsorensen/dotfiles](https://github.com/paulnsorensen/dotfiles).
Edit there, then run `dots sync` (or `chezmoi apply --force`) to
re-deploy.

## Background

Built from three Compass research artifacts:

1. The four-pillar grokking methodology (synthesis of Spinellis's
   *Code Reading*, Feathers's *Working Effectively with Legacy
   Code*, the C4 model, arc42, plus the modern senior-engineer
   onboarding playbook).
2. The reader-first / anti-slop design-doc workflow (Goedecke,
   Larson, Storey, plus the Microsoft+CMU CHI 2025 "cognitive debt"
   study).
3. The Cursor 2.5+ plugin spec (Skills, Rules, Commands, Hooks,
   Custom Modes, MCP).

## License

MIT — see `LICENSE`.
