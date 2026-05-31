# dotfiles wiki

Canonical cross-session knowledge for this dotfiles repo — architecture
decisions, conventions, and gotchas that aren't obvious from the code or git
history. Queried by agents via the hallouminate `ground` tool against the
`repo:dotfiles:wiki` corpus.

`AGENTS.md` remains the authoritative onboarding doc and command reference.
This wiki is for the *why* behind the *what*: design rationale, "this not that"
notes, and lessons that would otherwise be re-learned each session.

## Conventions

- **One topic per file.** The chunker splits on headings; two unrelated topics
  in one file degrade retrieval. Add a new file under a topic subdir instead.
- **Write the why, not the what.** Code and `AGENTS.md` already cover what
  things do. Capture rationale, trade-offs, and gotchas.
- Author via the hallouminate MCP (`add_markdown`) so ancestor `index.md` link
  trees and the LanceDB index refresh automatically. Edits made outside the MCP
  need a `hallouminate index` to be picked up.

## Sections

- [[architecture/index]] — how the repo configures AI agents: the `agents/`
  registry system and the `ap` tool that renders it into every harness.
- [[harnesses/index]] — the supported agent harnesses (Claude Code, Codex,
  opencode, Copilot): official docs per capability + how this repo wires each.
