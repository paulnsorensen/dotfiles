# Supported Harnesses

The repo deploys one harness-agnostic config (see [[../architecture/index]]) into four+ AI coding-agent CLIs. Each page below links the harness's **official upstream docs** for every capability and notes **how this repo wires it** through the `ap` renderer for that harness.

- [[claude]] — Claude Code (Anthropic). The primary harness; the only one supporting `ap` isolated launches.
- [[codex]] — OpenAI Codex CLI.
- [[opencode]] — opencode (sst/opencode).
- [[copilot]] — GitHub Copilot CLI.

> Cursor is also a render target (`renderers/cursor.py`) but is an IDE plugin surface, not a CLI harness; it's covered under `AGENTS.md` § Cursor Plugins rather than here.

## Capability support matrix

What each harness exposes natively. ✅ = first-class, ⚠️ = exists but indirect, ✗ = not available. Per-capability official links live on each harness page.

| Capability | Claude | Codex | opencode | Copilot |
|---|:---:|:---:|:---:|:---:|
| Hooks | ✅ | ✅ | ⚠️ (plugin API) | ✅ |
| Sub-agents / agent defs | ✅ | ✅ | ✅ | ✅ |
| MCP servers | ✅ | ✅ | ✅ | ✅ |
| System prompt / instructions | ✅ | ✅ (`AGENTS.md`) | ✅ | ✅ |
| Settings / config file | ✅ `settings.json` | ✅ `config.toml` | ✅ `opencode.json` | ✅ `settings.json` |
| Skills (`SKILL.md`) | ✅ | ✅ | ✅ | ✅ |
| Isolated closed-world launch (`ap` `isolated`) | ✅ | ✗ | ✗ | ✗ |

Notes:

- **opencode hooks** aren't a standalone feature — lifecycle events are exposed only through the plugin API (JS/TS).
- **Isolated launch** (`--strict-mcp-config` / `--setting-sources ""` / `--tools`) is Claude-CLI-specific; `ap` only builds those flags for Claude (see [[../architecture/agent-profile]] § launch).

## How the repo maps to each harness

| This repo's surface | Source of truth | Rendered into (per harness) |
|---|---|---|
| MCP servers | `agents/mcp/registry.yaml` | claude `.mcp.json` (plugin-scoped) · codex `config.toml [mcp_servers]` · opencode `opencode.json mcp` · copilot `~/.copilot/mcp-config.json` |
| Hooks | `agents/hooks/registry.yaml` | claude plugin `hooks/` · codex `hooks.json` · copilot `.github/hooks/` |
| Sub-agents | `agents/registry.yaml` + `agent_definitions/` | claude `.md` · codex `.toml` · opencode `.md` · copilot `.agent.md` |
| Skills | `skills/` + `skills/_registry.yaml` | copied (local) / `npx skills add` (external), all harnesses |
| System prompt | `agents/preamble.md` | claude `--system-prompt-file` · codex `model_instructions_file` · opencode `agents/build.md` |
| Global instructions | `agents/AGENTS.md` | `~/.claude/CLAUDE.md` · `~/.codex/AGENTS.md` |
