# Management Profile

A closed-world session for planning and coordination work: reading and writing across Notion, the repo wiki (hallouminate), and Linear, with GitHub reached through the `gh` CLI.

## Why this profile exists

The planning MCPs are opt-in — Notion and Linear both require OAuth and are only relevant when the work is coordination rather than coding. Launch this profile when working across design docs, tickets, and project trackers: Notion RFDs, Linear issues, and the dotfiles wiki.

## MCPs in scope

- **notion** — `mcp__notion__*` — read, search, create, and update pages, databases, and blocks in the connected Notion workspace.
- **linear** — `mcp__linear__*` — read, search, create, and update Linear issues, projects, and comments.
- **hallouminate** — `mcp__hallouminate__*` — query and edit per-repo markdown wikis (`ground`, `read_markdown`, `add_markdown`, `list_tree`).

## GitHub

No GitHub MCP. GitHub planning items (issues, projects, PRs) are handled by the `gh` CLI and the `/gh` skill via Bash, which work inside this isolated world. Use `git` for read-only local context.

## When to use

- Pulling context from a Notion design doc or Linear ticket into the working session.
- Drafting / updating an RFD or tech spec via `/rfd-coauthoring` or `/generate-design-doc`.
- Cross-referencing a Linear ticket against its linked Notion page or a wiki entry.
- Triaging GitHub issues (`/gh`, `/rennet`) against Linear/Notion records.
- Mirroring decisions made in chat back to the right tracker.

## Working standards

- **Calibrate claims.** Tag statements `<certain>` / `<speculative>` / `<don't know>`.
- **Be succinct.** Answer → minimal support → stop.
- Confirm the target page, database, or ticket before a write; don't create a new record when an existing one is meant.

## First-run authentication

On the first tool call against Notion or Linear in a fresh `dots profile launch claude mgmt` session, Claude Code prompts for OAuth per server. Approve once each; the tokens are stored by the respective MCP servers and reused on later launches.
