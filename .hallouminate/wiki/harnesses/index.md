# Supported Harnesses

The repo deploys one harness-agnostic config (see [[../architecture/index]]) into six active AI coding surfaces. Claude, Codex, Copilot, and Cursor are `ap` render targets; OMP and upstream Pi are separately managed global harnesses assembled by chezmoi. Each page links official upstream docs and the repo wiring for that harness.

- [[claude]] — Claude Code (Anthropic). The primary harness and an `ap` isolated-launch target.
- [[codex]] — OpenAI Codex CLI.
  - [[codex-hooks-schema]] — the `~/.codex/hooks.json` object-with-`hooks`-map shape the renderer must emit (a flat array parses as JSON but Codex rejects it).
  - [[../architecture/chezmoi-authoritative-codex]] — `~/.codex` converges on `dots sync` from `codex.yaml` + `private_dot_codex/`; why `config.toml` is merged rather than overwritten, and the chezmoi attribute-order and `private_` gotchas.
- [[copilot]] — GitHub Copilot CLI.
- [[cursor]] — Cursor. An IDE plugin surface and full `ap` render target; MCP flows through the shared registry while other capabilities ship through the plugin tree.
- [[omp]] — oh-my-pi. Not an `ap` target: `omp.yaml` + `dot_omp/` own its native config, agents, extensions, themes, and selected skills.
  - [[omp-plugins]] — milknado and hallouminate install as native OMP marketplace plugins reconciled by `sync_omp_plugins`.
- [[pi]] — upstream Pi coding agent. Not an `ap` target or OMP alias: `pi.yaml` + `dot_pi/` own its settings, models, MCP adapter, instructions, shared extensions/theme, and selected skills.

## Capability support matrix

What each harness exposes natively. ✅ = first-class, ⚠️ = exists but indirect, ✗ = not available. Per-capability official links live on each harness page.

| Capability | Claude | Codex | Copilot | Cursor | OMP | Pi |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Hooks / extension events | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Sub-agents / agent defs | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (package) |
| MCP servers | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ (adapter) |
| System prompt / instructions | ✅ | ✅ (`AGENTS.md`) | ✅ | ✅ (rules + `AGENTS.md`) | ✅ | ✅ (`AGENTS.md` + addendum) |
| Settings / config file | ✅ `settings.json` | ✅ `config.toml` | ✅ `settings.json` | ✅ `plugin.json` / `.cursor/` | ✅ `config.yml` | ✅ `settings.json` / `models.json` |
| Skills (`SKILL.md`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Isolated closed-world launch | ✅ (`ap`) | ✅ (`ap`, redirected `CODEX_HOME`) | ✗ | ✗ | ✅ (`PI_CONFIG_DIR`) | ✗ |

Notes:

- **OMP and Pi are native siblings, not `ap` render targets.** Their upstream schemas and discovery rules differ enough that a generic renderer would obscure ownership. Chezmoi authors each harness's native files and the sync assembler copies only deliberately shared resources.
- **Pi sub-agents and MCP are package-provided.** `pi-subagents` and `pi-mcp-adapter` supply those capabilities; `mcp.json` controls the adapter's server/tool projection.
- **Cursor** is an IDE, not a launchable CLI. Its non-MCP capabilities ship as a Cursor 2.x plugin tree; MCP flows through the shared registry.
- **Isolated launch** is implemented only where the harness has a tested closed-world lever: Claude and Codex through `ap`, OMP through `PI_CONFIG_DIR`. Copilot, Cursor, and Pi have no repo launcher that claims isolation.

## How the repo maps to each harness

| This repo's surface | Source of truth | Rendered into (per harness) |
|---|---|---|
| MCP servers | `agents/mcp/registry.yaml` plus native registries | Claude plugin `.mcp.json` · Codex `config.toml [mcp_servers]` · Copilot `mcp-config.json` · Cursor `mcp.json` · OMP `agent/mcp.json` · Pi `agent/mcp.json` through `pi-mcp-adapter` |
| Hooks | `agents/hooks/registry.yaml` plus native extensions | Claude plugin hooks · Codex `hooks.json` · Copilot `.github/hooks/` · Cursor plugin hooks · OMP/Pi TypeScript extensions |
| Cursor non-MCP capabilities | `cursor/plugins/local/<name>/` | `~/.cursor/{skills,rules,commands,hooks}/` plus merged `hooks.json` / `modes.json` |
| Sub-agents | `agents/registry.yaml` + native packages | Claude `.md` · Codex `.toml` · Copilot `.agent.md` · OMP native agents · Pi `pi-subagents` |
| Skills | `skills/` + `skills/_registry.yaml` | rendered/copied for all active harnesses; OMP and Pi exact trees are assembled before chezmoi applies |
| System prompt | `agents/preamble.md` + native addenda | Claude system-prompt file · Codex `model_instructions_file` · OMP/Pi launcher addenda |
| Global instructions | `agents/AGENTS.md` | `~/.claude/CLAUDE.md` · `~/.codex/AGENTS.md` · `~/.pi/agent/AGENTS.md` |
