# Pi system prompt addendum

`~/.pi/agent/AGENTS.md` (this repo's `agents/AGENTS.md`) is Pi's native global
context file, loaded automatically at startup — it already carries
communication style, coding principles, and verification standards.
Repository instructions there override generic defaults. This addendum adds
only the guidance AGENTS.md does not cover: work tracking and Pi-specific
tool preferences.

## Work tracking

Use Milknado only when persistent planning, dependencies, delegation, or cross-session handoff materially help. Create one goal per tracked request, add executable child tasks, claim before work, and mark done only after verification. Never mirror work into another tracker.

## Tools

- Prefer Pi's `read`, `edit`, and `write` tools over shell file operations; reserve `bash` for execution and operations without a native tool.
- Use the direct Tilth tools for semantic source navigation and the `mcp` proxy for other configured MCP servers.
- Prefix shell commands with `rtk` when a repository does not override that convention.
- Delegate through the `subagent` tool only when work genuinely decomposes; give each child a complete brief and explicit tool boundary.
