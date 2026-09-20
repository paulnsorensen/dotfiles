# Supported Harnesses

The repo deploys shared agent configuration into six active AI coding surfaces. Claude, Codex, Copilot, and Cursor are `ap` render targets. OMP and Pi use native chezmoi configuration.

- [[claude]] — Claude Code and an `ap` isolated-launch target.
- [[codex]] — OpenAI Codex CLI.
  - [[codex-hooks-schema]] defines the managed hook shape.
  - [[../architecture/chezmoi-authoritative-codex]] defines config ownership.
- [[copilot]] — GitHub Copilot CLI.
- [[cursor]] — Cursor IDE and CLI surfaces.
- [[omp]] — oh-my-pi, managed through `omp.yaml` and `dot_omp/`.
  - [[omp-plugins]] defines native marketplace and npm plugin ownership.
- [[pi]] — upstream Pi, managed through `pi.yaml` and `dot_pi/`.

## Capability support matrix

| Capability | Claude | Codex | Copilot | Cursor | OMP | Pi |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| Hooks / extension events | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Sub-agents / agent defs | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ package |
| MCP servers | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ adapter |
| System prompt / instructions | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Native settings | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Shared skills | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Isolated closed-world launch | ✅ | ✅ | ✗ | ✗ | ✅ | ✗ |

OMP and Pi remain native siblings rather than `ap` render targets. Their schemas and package systems need first-class ownership.

Pi reads the shared `~/.agents/skills` cache directly. It does not receive a copied skill tree.

## Repository mapping

| Surface | Source of truth | Destinations |
|---|---|---|
| MCP servers | shared and native registries | harness-native MCP files; Pi uses `agent/mcp.json` through `pi-mcp-adapter` |
| Hooks | `agents/hooks/registry.yaml` plus native extensions | harness-native hooks and OMP/Pi TypeScript extensions |
| Sub-agents | `agents/registry.yaml` plus native packages | rendered definitions and native agent packages |
| Skills | `skills/` plus `skills/_registry.yaml` | native trees and the shared `~/.agents/skills` cache |
| System prompt | `agents/preamble.md` plus native addenda | Claude/Codex prompt files and OMP/Pi addenda |
| Global instructions | `agents/AGENTS.md` | Claude, Codex, and Pi global context files |
| Modal input | native package registries | OMP `@sysid/pi-vim`; Pi `pi-vim` |
