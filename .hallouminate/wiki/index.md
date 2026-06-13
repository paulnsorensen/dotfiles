# dotfiles wiki

Canonical cross-session knowledge for this dotfiles repo — architecture
decisions, conventions, gotchas, and the operational reference. Queried by
agents via the hallouminate `ground` tool against the `repo:dotfiles:wiki`
corpus.

`AGENTS.md` is a **lean router**: repo overview, a topic map into this wiki, the
command cheat-sheet, and the always-in-context conventions. The detailed
reference — how the agent-config system, harnesses, MCPs, hooks, profiles, sync,
chezmoi, and the local environment actually work — lives **here**. Ground in the
relevant page rather than loading the whole reference into every session.

## Conventions

- **One topic per file.** The chunker splits on headings; two unrelated topics
  in one file degrade retrieval. Add a new file under a topic subdir instead.
- **Prefer the why, capture the what when it's the reference home.** Code still
  documents itself; lead with rationale, trade-offs, and gotchas, but the
  operational reference (commands, fields, paths) now lives here too, not in
  `AGENTS.md`.
- Author via the hallouminate MCP (`add_markdown`) so ancestor `index.md` link
  trees and the LanceDB index refresh automatically. Edits made outside the MCP
  (direct file writes) need a `hallouminate index` to be picked up.

## Sections

- [[architecture/index]] — how the repo configures AI agents: the `agents/`
  registry system, the `ap` tool that renders it into every harness, secret
  handling, config drift, and the cross-harness guards.
- [[harnesses/index]] — the supported agent harnesses (Claude Code, Codex,
  opencode, Copilot, Cursor): official docs per capability + how this repo wires each.
- [[operations/index]] — the operational plumbing: the sync + chezmoi deploy
  system, the opt-in local-LLM stack, and the local dev environment (git
  tooling, prek, plugins, skhd).
