# Zed

The Zed editor (zed.dev). Zed is an **IDE surface, not an `ap` render target**. Its native Agent Panel reads three global surfaces. The repo now feeds all three. Zed also hosts External Agents over ACP (Codex, Claude, OMP); those agents own their skills, MCPs, and rules natively. See [[../operations/zed-workspace-and-agents]] and [[../operations/zed-codex-acp]].

## Capabilities, docs, and repo wiring

| Capability | Official doc | This repo |
|---|---|---|
| Skills (`SKILL.md`) | [skills](https://zed.dev/docs/ai/skills) | Global dir `~/.agents/skills/<name>/`. Two writers: the `skills` CLI leg (`chezmoi/lib/install-external.sh`, `--agent zed`) for `skills/_registry.yaml` sources, and `install-local.sh` (via `run_onchange_after_install-local-skills.sh.tmpl`) for repo-local `skills/*`. Project skills: `<worktree>/.agents/skills/`. |
| Rules (system prompt) | [instructions](https://zed.dev/docs/ai/instructions) | `~/.config/zed/AGENTS.md`, copied from `agents/AGENTS.md` by `run_onchange_after_install-agents-doc.sh.tmpl`. Project rules follow Zed's precedence chain (`.rules` > `.cursorrules` > … > `AGENTS.md` > `CLAUDE.md`). The `@RTK.md` import line is literal text for Zed, as for Codex. |
| MCP | [mcp](https://zed.dev/docs/ai/mcp) | `context_servers` block in `chezmoi/dot_config/zed/settings.json.tmpl`. Hand-authored, not rendered from `agents/mcp/registry.yaml`. Rationale in [[../operations/zed-workspace-and-agents]]. |
| Sub-agents | [external agents](https://zed.dev/docs/ai/external-agents) | None native. `agent_servers` entries are ACP subprocesses, not agent definitions. `agent.profiles` scopes tools; it is not a subagent registry. |
| Hooks | — | No hook mechanism exists. Tool Permissions (allow/deny/confirm) are the closest control. |
| Settings / config | [configuring](https://zed.dev/docs/configuring-zed) | `chezmoi/dot_config/zed/{settings.json.tmpl,keymap.json,themes/}`. Regression: `tests/zed-config.bats`. |

## The shared skills dir has three writers

`~/.agents/skills/` is one directory with three owners. Zed reads all of it.

1. **`skills` CLI canonical store.** Every `npx skills add --global` writes the canonical copy here and tracks it in `~/.agents/.skill-lock.json`. Zed's own `globalSkillsDir` is this same path, so `--agent zed` adds no second copy.
2. **`ap` shared skill path.** `agent_profile/shared.py:copy_shared_skill` writes `.agents/skills/<name>` for Codex and Cursor compile targets. Live `ap` installs are retired; stale copies from that era can remain.
3. **`install-local.sh`.** Repo-local `skills/*` land here with a `.dotfiles-managed` manifest. The installer prunes only manifest-owned names and skips unmanaged dirs with a WARN.

Third-party installers (Superset, milknado) also write here. Nothing in the repo removes their dirs.

## Pruning: two passes in `install-external.sh`

- **Pass 1 — upstream drop.** `remove_stale_source_skills` compares each registered source's checkout with `npx skills list --global --json`. It removes names the source no longer ships. It passes the source's `--agent` flags.
- **Pass 2 — registry drop.** `remove_unregistered_skills` removes lock entries whose `source` is not in `skills/_registry.yaml`, or whose source has zero agents on this leg (for example `harnesses: [claude]` while `SKILL_EXCLUDE_AGENTS=claude-code`). It passes this leg's `--agent` flags. When `zed` is a leg agent, it then deletes `~/.agents/skills/<name>` unless `.dotfiles-managed` lists the name.

### Why the `--agent` flags matter

`npx skills remove <name> --global` **without** `--agent` targets every agent the CLI knows. That deletes `~/.claude/skills/<name>`, which chezmoi owns (`exact_`). The copy comes back on the next `dots sync`, but Claude runs without it until then. Always pass `--agent`.

### Why pass 2 deletes the canonical dir by hand

With `--agent cursor --agent zed`, the CLI keeps `~/.agents/skills/<name>` alive while any other detected agent still holds a copy at its own path. Claude's chezmoi copy always exists for a `harnesses: [claude]` source, so the canonical dir never goes away on its own. Zed reads that dir, so the script removes it after the CLI call. The lock entry is already gone at that point, so no lockfile inconsistency results.

## Gotchas

- `SKILL_HARNESSES` lives in the operator's `.env`. The leg targets Zed only when that list contains `zed`. `.env.example` shows the full list.
- `grok-codebase` exists in both `skills/` and `cursor/plugins/local/cheese-grok/skills/`. The cursor-plugins script runs first (alphabetical), so `install-local.sh` skips that one name in `~/.cursor/skills` with a WARN on every sync. Safe, noisy.
- `zed` is **not** in `SUPPORTED_ITEM_HARNESSES` (`agent_profile/harnesses.py`). A `harnesses: [zed]` entry in `skills/_registry.yaml` fails `ap` ingest. Add the enum entry only when a source needs Zed-specific scoping.
- The Zed skills feature landed around v1.4.x (2026-05); the machine runs 1.18.x. Source: [[../sources/index]] research slug `.cheese/research/zed-agent-skills-mcp-rules/`.
