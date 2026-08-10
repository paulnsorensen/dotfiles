# Supported Harnesses

The repo deploys one harness-agnostic config (see [[../architecture/index]]) into AI coding-agent surfaces along **two distinct paths**: five of the six `ap` render targets have a page below, and OMP is configured through chezmoi rather than `ap`. Each page links the harness's **official upstream docs** for every capability and notes **how this repo wires it**.

- [[claude]] — Claude Code (Anthropic). The primary harness; the only one supporting `ap` isolated launches.
- [[codex]] — OpenAI Codex CLI.
  - [[codex-hooks-schema]] — the `~/.codex/hooks.json` object-with-`hooks`-map shape the renderer must emit (a flat array parses as JSON but Codex rejects it).
  - [[../architecture/chezmoi-authoritative-codex]] — `~/.codex` converges on `dots sync` from `codex.yaml` + `private_dot_codex/`; why `config.toml` is merged rather than overwritten, and the chezmoi attribute-order and `private_` gotchas.
- [[opencode]] — opencode (sst/opencode).
- [[copilot]] — GitHub Copilot CLI.
- [[cursor]] — Cursor (the AI code editor). An IDE plugin surface, not a CLI harness, but a full `ap` render target — see its page for the MCP-via-registry vs plugin-tree split.
- [[omp]] — oh-my-pi. **Not an `ap` target**: configured entirely from `chezmoi/.chezmoidata/omp.yaml` + `chezmoi/dot_omp/`. Milknado is its sole work tracker (native Todo disabled and `/todo` consumed by an input extension), and it takes *no* entries from `agents/hooks/registry.yaml` — the hook synchronizer implements only Claude and Codex backends, so OMP ships native `~/.omp/agent/extensions/*.ts` instead.
  - [[omp-plugins]] — milknado and hallouminate install as native OMP marketplace plugins reconciled by `sync_omp_plugins`, replacing their former MCP entries and vendored-skill registrations.
- **Crush** (charmbracelet) is the sixth `ap` render target and has no page yet: it is a *partial* target by design — only MCP and `PreToolUse` hooks map onto its single merged `crush.json`; agents, skills, commands, and permissions are intentionally ignored, and it has no isolation lever (`agent_profile/renderers/crush.py`, `cli.py` `ALL_HARNESSES`).

## Capability support matrix

What each harness exposes natively. ✅ = first-class, ⚠️ = exists but indirect, ✗ = not available. Per-capability official links live on each harness page.

| Capability | Claude | Codex | opencode | Copilot | Cursor |
|---|:---:|:---:|:---:|:---:|:---:|
| Hooks | ✅ | ✅ | ⚠️ (plugin API) | ✅ | ✅ |
| Sub-agents / agent defs | ✅ | ✅ | ✅ | ✅ | ✅ |
| MCP servers | ✅ | ✅ | ✅ | ✅ | ✅ |
| System prompt / instructions | ✅ | ✅ (`AGENTS.md`) | ✅ | ✅ | ✅ (rules + `AGENTS.md`) |
| Settings / config file | ✅ `settings.json` | ✅ `config.toml` | ✅ `opencode.json` | ✅ `settings.json` | ✅ `plugin.json` / `.cursor/` |
| Skills (`SKILL.md`) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Isolated closed-world launch (`ap` `isolated`) | ✅ | ✅ (redirected `CODEX_HOME`) | ✅ (env config override) | ✗ | ✗ |

Notes:

- **OMP and Crush are deliberately absent from this matrix.** OMP is not rendered by `ap` at all, so a per-capability `ap` column would be meaningless — see [[omp]]. Crush is rendered, but only two capabilities map onto it (MCP, `PreToolUse` hooks); the rest are ignored by the renderer rather than missing from Crush, and this repo has not verified Crush's *native* surface. <speculative>Adding a Crush column would need an upstream-docs pass first.</speculative>
- **opencode hooks** aren't a standalone feature — lifecycle events are exposed only through the plugin API (JS/TS).
- **Cursor** is an IDE, not a launchable CLI — first-class hooks/agents/MCP/rules/skills, but no closed-world launch. Its non-MCP capabilities ship as a Cursor 2.x plugin tree; MCP flows through the shared registry. See [[cursor]].
- **Isolated launch** is implemented per harness: Claude uses CLI flags (`--strict-mcp-config`, `--setting-sources ""`, `--tools`), Codex redirects `CODEX_HOME`, and opencode uses `OPENCODE_*` env overrides; Cursor/Copilot have no launch wrapper. See [[../architecture/agent-profile]] § launch.

## How the repo maps to each harness

| This repo's surface | Source of truth | Rendered into (per harness) |
|---|---|---|
| MCP servers | `agents/mcp/registry.yaml` | claude plugin `.mcp.json` · isolated codex `CODEX_HOME/config.toml [mcp_servers]` · isolated opencode config content `mcp` · non-isolated global settings (`~/.codex/config.toml`, `opencode.json`, `~/.copilot/mcp-config.json`, `~/.cursor/mcp.json`) are now chezmoi/user-owned rather than `ap`-mutated |
| Hooks | `agents/hooks/registry.yaml` | claude plugin `hooks/` · codex `hooks.json` · copilot `.github/hooks/` |
| Cursor non-MCP capabilities | `cursor/plugins/local/<name>/` (e.g. `cheese-grok`) | `~/.cursor/{skills,rules,commands,hooks}/` + jq-merged `hooks.json` / `modes.json` (chezmoi `install-cursor-plugin.sh`, not the `ap` base render) |
| Sub-agents | `agents/registry.yaml` + `agent_definitions/` | claude `.md` · codex `.toml` · opencode `.md` · copilot `.agent.md` |
| Skills | `skills/` + `skills/_registry.yaml` | copied (local) / `npx skills add` (external), all harnesses |
| System prompt | `agents/preamble.md` | claude `--system-prompt-file` · codex `model_instructions_file` · opencode `agents/build.md` |
| Global instructions | `agents/AGENTS.md` | `~/.claude/CLAUDE.md` · `~/.codex/AGENTS.md` |
