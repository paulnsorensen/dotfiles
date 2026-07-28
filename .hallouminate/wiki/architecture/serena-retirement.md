# Serena retirement

Serena is no longer installed, configured, or exposed as an MCP in this dotfiles repository. Tilth is now the sole code-intelligence MCP; its symbol and caller queries replace Serena-specific routing and tool grants.[^1]

The removal also deletes the managed Serena package, chezmoi configuration, cleanup script, project-config skill, and Copilot template entry. Existing wiki references to Serena describe historical configurations and must not be treated as current routing guidance.[^2]

The July 2026 audit supports the removal: from 2026-07-01 through the 2026-07-25 ingestion, Claude used Serena 15 times in 5 of 391 sessions with tool calls (0.047% of calls); Codex used it zero times in 71 sessions. Fourteen of the Claude calls were generic `replace_content` edits and one was `replace_symbol_body`; no LSP reading, reference, diagnostic, or implementation operation was recorded. Tilth received 6,004 Claude and 854 Codex calls in the same period.[^3]

[^1]: agents/mcp/registry.yaml; agents/preamble.md; chezmoi/.chezmoidata/claude.yaml
[^2]: packages/packages.yaml; chezmoi/private_dot_copilot/mcp-config.json.tmpl; skills/serena-project-config/SKILL.md
[^3]: Session analytics: `python3 /Users/paul/.agents/skills/session-analytics/scripts/ingest.py --force`, then DuckDB queries of `tool_uses` and `tool_results` on 2026-07-25.

**Re-add race (2026-07-27):** PR #516 (pinning migration, merged Jul 25) branched before PR #512 (Serena removal, merged Jul 24) and reintroduced the `serena-agent` uv entry in `packages/packages.yaml` with a stale comment claiming the MCP registry still invoked it. Nothing consumed the binary. Removed again in PR #543 (entry + renovate annotation + pin-coverage test shrunk 14→13); machine-side `uv tool uninstall serena-agent` done the same day. Lesson: a pin-sweep PR that enumerates package entries can silently resurrect a package deleted on a parallel branch — after any wide packages.yaml merge, diff the entry list against intentional removals.
