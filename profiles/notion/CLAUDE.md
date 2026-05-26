# Notion Profile

This is a closed-world session: the only MCP loaded is Notion.

## Why this profile exists

The Notion MCP is opt-in: it requires OAuth, injects a tool surface that
isn't relevant to most coding sessions, and shouldn't auto-load. Launch
this profile when the work involves reading or writing Notion pages —
design docs, RFDs, project trackers, meeting notes.

## MCPs in scope

Defined in `profile.yaml` (closed world — `--strict-mcp-config`, so only the MCP below loads; the default dev MCPs are not present):

- **notion** — `mcp__notion__*` — read, search, create, and update pages,
  databases, and blocks in the connected Notion workspace.

## When to use

- Pulling context from a Notion design doc into the working session.
- Drafting / updating an RFD or tech spec via the `/rfd-coauthoring` or
  `/generate-design-doc` skills.
- Cross-referencing a Linear ticket against its linked Notion page.
- Mirroring decisions made in chat back to a Notion record.

## First-run authentication

On the first tool call in a fresh `dots profile launch claude notion` session, Claude Code will
prompt for OAuth. Approve once; the token is stored by the Notion MCP
server and reused on subsequent launches.
