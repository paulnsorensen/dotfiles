# Supported Harnesses

The repo deploys one harness-agnostic config (see [[../architecture/index]]) into five active AI coding surfaces. Claude, Codex, Copilot, and Cursor are `ap` render targets; OMP is a separately managed global harness assembled by chezmoi. Each page links official upstream docs and the repo wiring for that harness.

- [[claude]] — Claude Code (Anthropic). The primary harness and an `ap` isolated-launch target.
- [[codex]] — OpenAI Codex CLI.
  - [[codex-hooks-schema]] — the `~/.codex/hooks.json` object-with-`hooks`-map shape the renderer must emit (a flat array parses as JSON but Codex rejects it).
  - [[../architecture/chezmoi-authoritative-codex]] — `~/.codex` converges on `dots sync` from `codex.yaml` + `private_dot_codex/`; why `config.toml` is merged rather than overwritten, and the chezmoi attribute-order and `private_` gotchas.
- [[copilot]] — GitHub Copilot CLI.
- [[cursor]] — Cursor. An IDE plugin surface and full `ap` render target; MCP flows through the shared registry while other capabilities ship through the plugin tree.
- [[omp]] — oh-my-pi. Not an `ap` target: `omp.yaml` + `dot_omp/` own its native config, agents, extensions, themes, and selected skills.
  - [[omp-plugins]] — native marketplace plugins are reconciled by `sync_omp_plugins`.

## Capability support matrix

What each harness exposes natively. ✅ = first-class, ⚠️ = exists but indirect, ✗ = not available. Per-capability official links live on each harness page.

| Capability | Claude | Codex | Copilot | Cursor | OMP |
|---|:---:|:---:|:---:|:---:|:---:|
| Hooks / extension events | ✅ | ✅ | ✅ | ✅ | ✅ |
| Sub-agents / agent defs | ✅ | ✅ | ✅ | ✅ | ✅ |
| MCP servers | ✅ | ✅ | ✅ | ✅ | ✅ |
| System prompt / instructions | ✅ | ✅ (`AGENTS.md`) | ✅ | ✅ (rules + `AGENTS.md`) | ✅ |
| Settings / config file | ✅ `settings.json` | ✅ `config.toml` | ✅ `settings.json` | ✅ `plugin.json` / `.cursor/` | ✅ `config.yml` |
| Skills (`SKILL.md`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Isolated closed-world launch | ✅ (`ap`) | ✅ (`ap`, redirected `CODEX_HOME`) | ✗ | ✗ | ✅ (`PI_CONFIG_DIR`) |

Notes:

- **OMP is a native harness, not an `ap` render target.** Its upstream schema and discovery rules differ enough that a generic renderer would obscure ownership. Chezmoi authors its native files and the sync assembler copies only deliberately shared resources.
- **Cursor** is an IDE, not a launchable CLI. Its non-MCP capabilities ship as a Cursor 2.x plugin tree; MCP flows through the shared registry.
- **Isolated launch** is implemented only where the harness has a tested closed-world lever: Claude and Codex through `ap`, OMP through `PI_CONFIG_DIR`. Copilot and Cursor have no repo launcher that claims isolation.

## How the repo maps to each harness

| This repo's surface | Source of truth | Rendered into (per harness) |
|---|---|---|
| MCP servers | `agents/mcp/registry.yaml` plus native registries | Claude plugin `.mcp.json` · Codex `config.toml [mcp_servers]` · Copilot `mcp-config.json` · Cursor `mcp.json` · OMP `agent/mcp.json` |
| Hooks | `agents/hooks/registry.yaml` plus native extensions | Claude plugin hooks · Codex `hooks.json` · Copilot `.github/hooks/` · Cursor plugin hooks · OMP TypeScript extensions |
| Cursor non-MCP capabilities | `cursor/plugins/local/<name>/` | `~/.cursor/{skills,rules,commands,hooks}/` plus merged `hooks.json` / `modes.json` |
| Sub-agents | `agents/registry.yaml` + native packages | Claude `.md` · Codex `.toml` · Copilot `.agent.md` · OMP native agents |
| Skills | `skills/` + `skills/_registry.yaml` | rendered/copied for all active harnesses; OMP's exact tree is assembled before chezmoi applies |
| System prompt | `agents/preamble.md` + native addendum | Claude system-prompt file · Codex `model_instructions_file` · OMP launcher addendum |
| Global instructions | `agents/AGENTS.md` | `~/.claude/CLAUDE.md` · `~/.codex/AGENTS.md` |
