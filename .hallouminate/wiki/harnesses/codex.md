# OpenAI Codex CLI

OpenAI's coding-agent CLI. Config lives under `~/.codex/`, centred on `config.toml`. Docs root: [developers.openai.com/codex](https://developers.openai.com/codex).

The repo seeds/writes `~/.codex/config.toml` through chezmoi/prompt installers; non-isolated `ap install global` no longer mutates the live `[mcp_servers]` table. `ap` writes Codex agents, hooks, shared skills, and isolated-profile config only.

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Hooks | <https://developers.openai.com/codex/hooks> | `agents/hooks/registry.yaml` → `~/.codex/hooks.json`. `matcher` (e.g. `startup\|resume\|clear`) is codex-only for SessionStart. `timeout` in seconds. |
| Sub-agents | <https://developers.openai.com/codex/subagents> | `agents/registry.yaml` → `~/.codex/agents/<n>.toml` (`name`, `description`, `developer_instructions`). Read-only agents get `sandbox_mode = "read-only"` derived from their tool list. |
| MCP | <https://developers.openai.com/codex/mcp> | Isolated `ap launch codex <profile>` writes generated `[mcp_servers]` tables under redirected `CODEX_HOME`; non-isolated global installs leave live `~/.codex/config.toml` to chezmoi/user ownership. Env keys present in `.env` are scrubbed from isolated rendered tables (see env-scrub below). |
| System prompt | [AGENTS.md cascade](https://developers.openai.com/codex/guides/agents-md) · [`model_instructions_file` key](https://developers.openai.com/codex/config-reference) | `agents/preamble.md` wired as `model_instructions_file` in `config.toml` (`install-prompts`). `agents/AGENTS.md` → `~/.codex/AGENTS.md` (the instruction chain: `~/.codex/AGENTS.md` → repo root → cwd, concatenated root-down). The `model_instructions_file` key ("replacement for built-in instructions instead of AGENTS.md") is documented in the config reference, the cascade order in the AGENTS.md guide. |
| Settings / config | <https://developers.openai.com/codex/config-reference> | `~/.codex/config.toml`. Base copied once; thereafter user-owned. Searchable schema of every key (agents, approval policy, providers, features incl. hooks, permissions, sandbox, `[mcp_servers]`, OTel). |
| Skills | <https://developers.openai.com/codex/skills> | `skills/` → shared `.agents/skills/<n>/`. Codex **does** support `SKILL.md` skills (progressive disclosure). |

## Isolated settings

`ap launch codex <profile>` isolates by redirecting `CODEX_HOME` to a fresh generated home, not by passing a `--strict-mcp-config` / `--setting-sources` equivalent. The generated `config.toml` carries the profile MCP world, optional `model_instructions_file`, and the repo's Auto permission defaults: `approval_policy = "on-request"`, `approvals_reviewer = "auto_review"`, and `sandbox_mode = "workspace-write"`.[^isolated-auto-perms] Codex still has no per-launch built-in tool whitelist; per-server enable/disable is the only MCP filtering Codex exposes (no per-tool filtering via `codex mcp`).

[^isolated-auto-perms]: `agent-profile/agent_profile/overlay.py:_write_codex_config`; regression test `agent-profile/tests/test_overlay.py:test_codex_isolated_config_defaults_to_auto_permissions`.

## Quirks

- **Env-scrub**: `zsh/core.zsh` exports `.env` into the interactive shell, so codex children inherit those credentials at runtime. The renderer therefore strips `.env` keys from `[mcp_servers.*.env]` to avoid duplicating secrets as plaintext on disk. Render-time per-harness vars (e.g. `SERENA_MUX_HARNESS`) stay baked. Override with `AP_CODEX_INHERIT_ENV=0`.
- **Legacy hook migration**: the renderer one-time-removes legacy `[[hooks.<event>]]` blocks (written by the retired `agents/hooks/sync.sh`) so a managed hook doesn't fire twice — Codex merges `hooks.json` + `config.toml` hooks at load.

## Skill discovery hypotheses and failure modes

When Codex appears not to have a repo skill, distinguish four different cases before blaming `ap`:

1. **Using slash-command syntax for a skill.** Codex does not create one slash command per skill. Official Codex docs list `/skills` as the skill picker and `$<skill-name>` as explicit skill mention; `/harness-doctor` is not a valid Codex skill invocation. Custom prompts can be slash-invoked as `/prompts:<name>`, but those are deprecated and are a separate mechanism from skills.

2. **Installed but omitted from the initial prompt.** Codex's official skills docs say the initial in-context skill list is capped (roughly 2% of context, or 8,000 chars when unknown), and large installs may have skills omitted from that list. That cap only affects discovery/implicit routing; Codex can still read the full `SKILL.md` when a skill is selected. This explains a session where `harness-doctor` existed under `~/.agents/skills/harness-doctor/SKILL.md` and was listed by `npx --yes skills list --global`, but the session's advertised skill list did not mention it. Long frontmatter descriptions make this worse: `harness-doctor` had a 1,042-character description during the 2026-06-12 audit.

3. **External source name is not the installed skill name.** `skills/_registry.yaml:22` declares `paulnsorensen/easy-cheese`, and `agent-profile/agent_profile/fetch.py:122-130` fetches it with `npx --yes skills add <source> --skill '*' --agent ... -g --copy -y`. The `skills` CLI installs each skill by its own `SKILL.md` `name` (for example `cheez-search`, `age`, `cook`), not by a `easy-cheese:<name>` namespace. So `$easy-cheese:cheez-search` is not the same thing as `$cheez-search`.

4. **Stale source-qualified references can leak into rendered agent metadata.** `agents/registry.yaml` still used `easy-cheese:cheez-search`, `easy-cheese:cheez-read`, and `easy-cheese:cheez-write` in several agent `skills:` lists during the 2026-06-12 audit (`agents/registry.yaml:27`, `:63`, `:109`, `:216-217`, `:232-233`, `:250-251`, `:268-270`). The live install showed the actual Easy Cheese skills present as un-namespaced directories, but rendered Claude agent frontmatter still referenced `easy-cheese:...`. Treat that as a dotfiles bug, not a missing install; fix the registry references or make renderers normalize source-qualified names.

Fast diagnosis checklist:

```bash
npx --yes skills list --global
# Look for the skill's actual installed name and path.

ls ~/.agents/skills/<name>/SKILL.md
ls ~/.codex/skills/<name>/SKILL.md  # optional compatibility mirror, not Codex's only source

python3 - <<'PY'
import tomllib, pathlib
print(tomllib.loads(pathlib.Path('~/.codex/config.toml').expanduser().read_text()).get('skills'))
PY
# If this prints None, no [[skills.config]] disables are present.
```

If a skill is on disk and not disabled, first suspect wrong invocation syntax, initial-list budget, or a naming mismatch. If it is absent from disk, inspect `skills/_registry.yaml`, `agent-profile/agent_profile/fetch.py`, and the last `dots sync` / `dots profile install global` output.
