# AGENTS.md — `agent-profile/` (the `ap` renderer)

The Python package behind `ap`: it lowers the declarative registries + profiles
(`agents/`, `profiles/`) into per-harness config for Claude, Codex, opencode,
Cursor, and Copilot. Architecture and rationale live in the wiki — ground there
before non-trivial work:

- [[architecture/agent-profile]] — install vs launch, profiles, the renderers.
- [[architecture/harness-permissions]] — the three permission levers and what
  each renderer emits today.

## Habit: a renderer behavior change updates the wiki in the same change

When you change *what a renderer emits* — a permission lever, a posture/sandbox
default, MCP-tool scoping, an output file path, install-vs-launch behavior —
update the matching wiki page **in the same commit/PR**, then reindex. The wiki
is the cross-session source of truth for "what `ap` renders today"; a renderer
change that skips it ships stale docs the next agent trusts wrongly.

Where each change lands:

| Change | Wiki page |
|---|---|
| permissions / posture / MCP scoping | `architecture/harness-permissions.md` — the *What `ap` renders today* table, the per-lever sections, and *Planned fixes* |
| install vs launch, isolated profiles, profile schema | `architecture/agent-profile.md` |
| per-harness wiring quirks | `harnesses/<harness>.md` |

Rules for the wiki edit:

- **Cite the code.** Every render claim names `renderers/<harness>.py:<lines>`
  (or `overlay.py`) plus the regression test, so it stays verifiable.
- **Reindex.** After a direct file edit, run `hallouminate index` (or write via
  the `add_markdown` MCP) — a direct write is not searchable otherwise.
- **Fix the whole page, not one cell.** Stale render claims cluster: the table,
  the TL;DR, the *Net* line, and *Planned fixes* all describe the same behavior,
  so correct them together or the page contradicts itself.

Why this rule exists: #264 / #272 / #324 each changed Codex permission rendering
but left `harness-permissions.md` asserting the opposite ("`ap` doesn't target
`sandbox_mode`", "renders MCP scoping for none of them"). A `/session-analytics`
pass caught the drift later. Folding the wiki update into the renderer change is
what keeps it from happening again.
