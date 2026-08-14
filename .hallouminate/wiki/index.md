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

- [[architecture/index]] — how the repo configures AI agents through shared
  registries, the four-target `ap` compiler, and chezmoi-managed native
  harnesses, including secret handling, config drift, and cross-harness guards.
- [[harnesses/index]] — the supported agent harnesses (Claude Code, Codex,
  Copilot, Cursor, OMP): official docs and repo wiring per capability.
- [[operations/index]] — the operational plumbing: the sync + chezmoi deploy
  system, the opt-in local-LLM stack, and the local dev environment (git
  tooling, prek, plugins, skhd).
- [[adr/index]] — repo-wide accepted decision records (context / decision /
  alternatives / consequences): the cheese-factory workflow, manifest-pinned
  packages, the sub-agent routing overhaul, the Codex+OMP harness upgrade, and
  machine-aware vault selection.
- [[decisions/index]] — the `session-convergence` ADR series (analytics access,
  where the convergence sweep lives, wheypoint provenance fields).
- [[domain-model]] — the ubiquitous language for this repo's agent-orchestration
  domain. Merge into it; don't overwrite.
- [[log]] — the ingest log: one line per page created or merged, with the commit
  that prompted it.

**Three ADR homes exist**, and the split is historical rather than designed:
`adr/` (repo-wide), `decisions/` (the session-convergence series only), and
ADRs authored beside their topic page (`architecture/agent-secret-isolation-00N`).
Before adding a new record, put it where its *siblings* live rather than
inventing a fourth home. <speculative>Consolidating the first two is probably
right, but nothing in the repo settles which name wins.</speculative>

- [[sources/index]] — localized vendor evidence: what an external doc or
  upstream source actually says, verified and dated, so a page here can cite a
  claim instead of restating a guess.
