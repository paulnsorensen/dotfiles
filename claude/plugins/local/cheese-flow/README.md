# cheese-flow

Cheddar Flow agent pipeline — cheese-themed development workflow tools for Claude Code.

## Dependencies

**Required MCP:** [`code-review-graph`](https://github.com/tirth8205/code-review-graph) — the `explore-graph` sub-agent wraps its MCP tools for structural graph queries (semantic search, call chains, impact radius, flows, architecture overview, communities). Without it, `/explore` still runs but loses the graph dimension.

Add it to your MCP registry (`claude/mcp/registry.yaml`) and run `mcp-sync`:

```yaml
code-review-graph:
  command: uvx
  args: [code-review-graph, serve]
  scope: user
```

## Commands

| Command | Purpose |
|---------|---------|
| `/explore [--scope <dir>] [--budget <N>] [--out <path>] <query>` | Parallel code exploration — dispatches four sub-agents and writes an XML artifact to `.claude/exploration/<slug>.xml`. |
| `/hello` | Smoke test — confirms the plugin is loaded. |

## Skills

| Skill | Purpose |
|-------|---------|
| `explore` | Orchestrator for `/explore`. Parses the query, dispatches sub-agents in parallel, synthesizes an XML artifact. |
| `hello-cheese` | Example skill demonstrating TypeScript script execution via `${CLAUDE_PLUGIN_ROOT}`. |

## Agents

All four agents are sub-agents spawned by the `explore` skill. They return structured JSON only.

| Agent | Model | Role |
|-------|-------|------|
| `explore-graph` | sonnet | Wraps `code-review-graph` MCP for multi-hop structural queries. |
| `explore-lsp` | sonnet | Wraps the built-in LSP tool for type-aware single-hop navigation. |
| `explore-tilth` | sonnet | Wraps the `tilth` CLI for Tree-sitter token-budgeted reads. |
| `explore-tokei` | haiku | Wraps `tokei` for language breakdowns and file-size rankings. |

## Architecture

`/explore` is a skill (not an agent) because Claude Code supports only one level of sub-agent nesting. Skills run inline in the caller's context, so the `explore` skill's `Agent()` calls create first-level sub-agents.

## License

MIT — see [LICENSE](LICENSE).
