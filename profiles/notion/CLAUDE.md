# Notion Profile

A closed-world session for working with Notion: read and write pages, databases, and blocks in the connected workspace.

## Why this profile exists

The Notion MCP is opt-in — it requires OAuth and is only relevant when the work involves Notion. Launch this profile when reading or writing Notion records: design docs, RFDs, project trackers, meeting notes.

## MCP in scope

- **notion** — `mcp__notion__*` — read, search, create, and update pages, databases, and blocks in the connected Notion workspace.

## When to use

- Pulling context from a Notion design doc into the working session.
- Drafting / updating an RFD or tech spec via `/rfd-coauthoring` or `/generate-design-doc`.
- Cross-referencing a Linear ticket against its linked Notion page.
- Mirroring decisions made in chat back to a Notion record.

## Working standards

- **Calibrate claims.** Tag statements `<certain>` / `<speculative>` / `<don't know>`.
- **Be succinct.** Answer → minimal support → stop.
- Confirm the target page or database before a write; don't create a new record when an existing one is meant.

## First-run authentication

On the first tool call in a fresh `dots profile launch claude notion` session, Claude Code prompts for OAuth. Approve once; the token is stored by the Notion MCP server and reused on later launches.
