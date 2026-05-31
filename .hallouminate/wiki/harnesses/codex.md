# OpenAI Codex CLI

OpenAI's coding-agent CLI. Config lives under `~/.codex/`, centred on `config.toml`. Docs root: [developers.openai.com/codex](https://developers.openai.com/codex).

The repo seeds `~/.codex/config.toml` once (chezmoi `install-codex`, first-time only — then user-owned); `ap`'s codex renderer (`renderers/codex.py`) mutates only the `[mcp_servers]` table and writes agent/hook artifacts alongside.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://developers.openai.com/codex/hooks> | `agents/hooks/registry.yaml` → `~/.codex/hooks.json`. `matcher` (e.g. `startup\|resume\|clear`) is codex-only for SessionStart. `timeout` in seconds. |
| Sub-agents | <https://developers.openai.com/codex/subagents> | `agents/registry.yaml` → `~/.codex/agents/<n>.toml` (`name`, `description`, `developer_instructions`). Read-only agents get `sandbox_mode = "read-only"` derived from their tool list. |
| MCP | <https://developers.openai.com/codex/mcp> | `agents/mcp/registry.yaml` → `config.toml [mcp_servers]` (tomlkit round-trip, preserves user keys). No scopes. Env keys present in `.env` are scrubbed from the rendered table (see env-scrub below). |
| System prompt | [AGENTS.md cascade](https://developers.openai.com/codex/guides/agents-md) · [`model_instructions_file` key](https://developers.openai.com/codex/config-reference) | `agents/preamble.md` wired as `model_instructions_file` in `config.toml` (`install-prompts`). `agents/AGENTS.md` → `~/.codex/AGENTS.md` (the instruction chain: `~/.codex/AGENTS.md` → repo root → cwd, concatenated root-down). The `model_instructions_file` key ("replacement for built-in instructions instead of AGENTS.md") is documented in the config reference, the cascade order in the AGENTS.md guide. |
| Settings / config | <https://developers.openai.com/codex/config-reference> | `~/.codex/config.toml`. Base copied once; thereafter user-owned. Searchable schema of every key (agents, approval policy, providers, features incl. hooks, permissions, sandbox, `[mcp_servers]`, OTel). |
| Skills | <https://developers.openai.com/codex/skills> | `skills/` → shared `.agents/skills/<n>/`. Codex **does** support `SKILL.md` skills (progressive disclosure). |

## Isolated settings

Not available. Codex has no `--strict-mcp-config` / `--setting-sources` equivalent; `ap` only builds isolated-launch flags for Claude. Per-server enable/disable is the only MCP filtering Codex exposes (no per-tool filtering via `codex mcp`).

## Quirks

- **Env-scrub**: `zsh/core.zsh` exports `.env` into the interactive shell, so codex children inherit those credentials at runtime. The renderer therefore strips `.env` keys from `[mcp_servers.*.env]` to avoid duplicating secrets as plaintext on disk. Render-time per-harness vars (e.g. `SERENA_MUX_HARNESS`) stay baked. Override with `AP_CODEX_INHERIT_ENV=0`.
- **Legacy hook migration**: the renderer one-time-removes legacy `[[hooks.<event>]]` blocks (written by the retired `agents/hooks/sync.sh`) so a managed hook doesn't fire twice — Codex merges `hooks.json` + `config.toml` hooks at load.
