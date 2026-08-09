# AGENTS.md

Dotfiles repo for a vim-centric, macOS-oriented terminal environment: zsh, git, and harness-agnostic agent configuration. The root `CLAUDE.md` imports this file.

## Ground first

This is a router, not the full reference. Before changing agent config, harness wiring, `ap`, registries, chezmoi, sync, or local-LLM plumbing, query `repo:dotfiles:wiki` with `ground`, `read_markdown`, or `list_tree`.

When work establishes a durable decision or gotcha, record its *why* with `add_markdown`; direct wiki edits require `hallouminate index`.

## Topic map

| Topic | Wiki page |
|---|---|
| Registries, MCPs, hooks, agents, skills, system prompt | [[architecture/agents-dir]] |
| Plugins across harnesses | [[architecture/cross-harness-plugins]] |
| `ap` profiles, renderers, install/launch | [[architecture/agent-profile]] |
| MCP credential isolation | [[architecture/agent-secret-isolation-001]] |
| Config drift and settings repair | [[architecture/config-drift]] |
| Codex-authoritative chezmoi regime | [[architecture/chezmoi-authoritative-codex]] |
| Harness wiring | [[harnesses/index]] |
| Sync and chezmoi | [[operations/sync-and-chezmoi]] |
| Git tooling, prek, Claude plugins, skhd | [[operations/dev-environment]] |
| Remote access | [[operations/remote-access]] |

**Layout:** `bin/` (live CLI), `agents/` (registries and definitions), `agent-profile/` (`ap`), `profiles/`, harness directories, `skills/`, `chezmoi/`, `packages/`, `zsh/`, `tests/`, and `.hallouminate/wiki/`.

## Source of truth

Never edit a rendered target. Edit the source, then deploy.

| Change | Edit | Deploy |
|---|---|---|
| Claude MCP, hook, agent, skill, permissions, or marketplace | `chezmoi/.chezmoidata/claude.yaml` (+ referenced source files) | `dots sync` |
| Sub-agent definition | `agents/registry.yaml` + `agents/agent_definitions/` + `claude.yaml` | `dots sync` |
| Local/external skill | `skills/` or `skills/_registry.yaml` + `claude.yaml` | `dots sync` |
| Cross-harness plugin | `agents/plugins/registry.yaml` | `dots sync` or `plugin-sync` |
| Claude-native plugin | `claude/plugins/registry.yaml` | `dots sync` |
| Codex MCP, config scalar, or agent selection | `chezmoi/.chezmoidata/codex.yaml` | `dots sync` |
| Cursor plugin | `cursor/plugins/local/<name>/` | `dots sync` |
| Package / profile / OMP config | `packages/packages.yaml` / `profiles/<name>/profile.yaml` / `chezmoi/.chezmoidata/omp.yaml` | relevant `dots` command |
| Secret (API key, token) | the vault — never `.env`. Key names: `secrets/secrets.env.tmpl` | run `bin/vault-provision` as the operator |

`.env` holds only non-secret settings. `bin/vault-provision` reads the exact
runtime fields from 1Password (`op`) or Bitwarden Secrets Manager (`bws`) and
installs one root-owned credential, policy, and service identity per consumer.
Harness MCP configs contain only fixed `agent-secret-proxy` socket paths; daily
loaders remove retired credential names and the obsolete user cache before exec.

Claude-global and Codex-global configuration are chezmoi-authoritative; opencode,
Cursor, and Copilot remain frozen pending migration.

Codex hooks are not declared in `codex.yaml` — they derive from
`agents/hooks/registry.yaml` (entries whose `harnesses` includes codex).
`~/.codex/config.toml` is merged, not overwritten: the CLI writes its own runtime
state (`projects`, `hooks.state`, `marketplaces`, `plugins`) into the same file, so
only registry-declared keys are overlaid. `mcp_servers` is the exception — it is
replaced wholesale, so deleting a server there evicts it from the live file.

## Required gates

1. Run `dots sync` after registry, skill, agent, plugin, or docs-source changes, and before committing.
2. Before completion or commit, run `just check`; completion requires exit 0. Name any unrun leg.
3. New shell logic belongs in a sourced library with Bats coverage; keep `.sync` scripts to parsing and dispatch.
4. For chezmoi: never commit plaintext secrets; never edit managed targets; run `chezmoi --source $DOTFILES/chezmoi diff` before template changes; use `prompt*` only in `.chezmoi.toml.tmpl`.

## Commands

`dots sync`, `dots test`, `dots doctor`, `dots claude diff`, `dots profile list|describe|launch`

`mcp-edit`, `hook-edit`, `agent-edit`, `skill-edit`, `plugin-edit`; `cc`, `ccc`, `ccr`, `ccp <name>`; `ccw` and `wt-git`.

## Repo-specific gotchas

- `bin/` runs live from the clone; its edits need no chezmoi apply.
- New `zsh/` files need an ordered `zshrc` source entry.
- Reference docs belong in gitignored `reference/`.
- `git commit --no-verify` is only for rare temporary prek overrides.
- Prefix shell commands with `rtk`; see `~/.claude/RTK.md` or `rtk --help`.
