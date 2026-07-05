# AGENTS.md

Project instructions for any coding agent in this dotfiles repo — Claude Code, Cursor, Codex, Copilot CLI, Antigravity, and friends. The root `CLAUDE.md` imports this via `@AGENTS.md`.

**This file is a lean router, not the full reference.** It carries the repo overview, a topic map into the hallouminate wiki, the command cheat-sheet, and the always-in-context conventions. The detailed reference — how the agent-config system, harnesses, MCPs, hooks, profiles, sync, and chezmoi actually work — lives in the wiki (`repo:dotfiles:wiki`). Ground there for the detail; don't expect it inline.

## Ground first

Before non-trivial work touching agent config, harness wiring, `ap`, the registries, chezmoi, or the local-LLM / sync / dev-environment plumbing, query the wiki:

- `ground "<question>"` (semantic search), or `read_markdown` / `list_tree` via the hallouminate MCP against `repo:dotfiles:wiki`.
- The **Topic Map** below names the page that owns each topic.

**Maintain it at session end.** When you establish a non-obvious fact, decision, or gotcha a future agent would otherwise re-learn, write it back via `add_markdown` (follow `.hallouminate/wiki/index.md` conventions — one topic per file, capture the *why*, link with `[[name]]`). The `/wiki-curator` skill drives larger doc updates. Direct file writes (not via the MCP) need a `hallouminate index` to be picked up.

## Repository Overview

A personal dotfiles repo configuring a vim-centric, terminal-based dev environment (macOS-oriented): zsh shell, git, and a harness-agnostic AI-agent config system. One source of truth (`agents/` registries) renders into Claude Code, Codex, opencode, Cursor, and Copilot via the `ap` tool. chezmoi handles templated / per-machine / secret files; the rest deploys via `dots sync`.

## Topic Map

| Topic | Wiki page |
|---|---|
| `agents/` registry system (MCP / hook / sub-agent / skill / plugin registries, system-prompt body) | [[architecture/agents-dir]] |
| Cross-harness plugin decomposition (`_expand_plugins`, registry schema, per-harness reach) | [[architecture/cross-harness-plugins]] |
| `ap` tool — profiles (base / global / isolated), the five renderers, install vs launch, chezmoi drive | [[architecture/agent-profile]] |
| MCP `${VAR}` secret passthrough | [[architecture/mcp-secret-handling]] |
| Config drift + the `settings.json` self-heal (`/harness-doctor`) | [[architecture/config-drift]] |
| Cross-harness guards (git-guard + Claude pre-tool guards) | [[architecture/cross-harness-guards]] |
| Per-harness wiring + official docs (claude / codex / opencode / copilot / cursor) | [[harnesses/index]] |
| Cursor plugin deploy (`cheese-grok`) | [[harnesses/cursor]] |
| opencode settings (tui / theme) | [[harnesses/opencode]] |
| Local LLM stack (llama.cpp + LiteLLM, opt-in) | [[operations/local-llm]] |
| Sync system + chezmoi-managed files | [[operations/sync-and-chezmoi]] |
| Git tooling (difftastic / mergiraf), prek, Claude plugins, skhd | [[operations/dev-environment]] |
| Remote access (Tailscale + mosh + tmux), the `mtmux` wrapper | [[operations/remote-access]] |

**Repo layout:** `bin/` (live-from-clone CLI incl. `dots`), `agents/` (harness-agnostic config + registries + `agent_definitions/`), `agent-profile/` (the `ap` package), `profiles/`, `claude/` `codex/` `cursor/` (harness-specific), `skills/`, `chezmoi/` (templated deploys), `packages/`, `zsh/`, `tests/` (bats), `.hallouminate/wiki/`.

## Key Commands

### dots

- `dots sync` — deploy (symlinks, packages, claude source assembly + chezmoi apply). `dots sync refresh` forces package re-check.
- `dots upgrade` (`up`) · `dots update` (pull + sync) · `dots status` · `dots doctor` (health + chezmoi + local-llm) · `dots test` (bats suite)
- `dots rollback` — prints the git-backed undo path (`git revert` + `dots sync`); no stateful snapshots.
- `dots claude diff` — preview pending chezmoi changes under `~/.claude` (settings.json + exact_ trees) before a sync overwrites them wholesale; does not cover `~/.claude.json` MCP drift (reconciles via the claude CLI).
- `dots profile launch claude <name>` · `dots profile list` · `dots profile describe <name>`

### Agent config — edit a registry, then sync

- `mcp-edit` (opens the claude registry `chezmoi/.chezmoidata/claude.yaml`) / `hook-edit` / `agent-edit` / `skill-edit` / `plugin-edit` — open the source registry
- Deploy is `dots sync` for everything claude-global (`base-sync` retired; other harnesses frozen pending their migration spec). `plugin-sync` for Claude marketplace plugins
- `mcp-ls` / `hook-ls` / `skill-ls` / `plugin-ls` · `mcp-add <name> <cmd> [args…]` (hand-add outside the registry — prefer `mcp-edit` + `dots sync`)
- `cc` / `ccc` / `ccr` — launch claude (preamble system-prompt wired) · `ccs` (fzf-jump to a running session) · `ccp <name>` (scoped profile)
- `ccw <slug>` / `ccw <repo>/<slug>` (cross-repo) / `ccw` (fzf resume picker) · `ccw-ls` / `ccw-rm <slug>` / `ccw-sweep` / `ccw-clean` · `wt-git <path> <cmd>` — worktrees
- `claude-settings` · `claude-json-prune [--apply]` · `cf-refresh` (= `plugin-refresh cheese-flow local`)

### GitHub

- `gh-pr-review <PR#>` · `gh-pr-prep` · `gh-issue-context <#>` · `gh-pr-batch <PR#…>` · `gh-pr-checks-batch <PR#…>`

### Misc

- `zrl` (reload zsh) · `uuidg` · `cdd` (→ `~/Dev`) · `skr` (skhd reload) · `mtmux <host> [sess]` (Tailscale+mosh+tmux remote shell)

## Repo Conventions

**Edit → sync.** Never hand-edit a rendered artifact — edit the source registry, then deploy. Mechanics: [[architecture/agents-dir]] + [[architecture/agent-profile]].

Global **claude** config is chezmoi-authoritative: the claude registry `chezmoi/.chezmoidata/claude.yaml` selects MCPs, settings hooks wiring, enabledPlugins/marketplaces, permissions, skills, and agents; `dots sync` assembles + applies, and **removals propagate** (exact_ dirs, settings authored wholesale, MCP reconcile via manifest). Other harnesses read the `agents/` registries but are frozen pending their own migration spec.

| Add a… | Edit | Deploy |
|---|---|---|
| MCP (claude, user scope) | `chezmoi/.chezmoidata/claude.yaml` `mcps:` | `dots sync` |
| Hook (claude settings wiring) | `chezmoi/.chezmoidata/claude.yaml` `hooks:` (+ script in `agents/hooks/`) | `dots sync` |
| Sub-agent | `agents/registry.yaml` + `agents/agent_definitions/` + list in `claude.yaml` `agents:` | `dots sync` |
| Skill | `skills/` (local, listed in `claude.yaml` `skills:`) or `skills/_registry.yaml` (external, vendored) | `dots sync` |
| Claude permissions / enabledPlugins / marketplaces | `chezmoi/.chezmoidata/claude.yaml` | `dots sync` |
| Plugin (cross-harness) | `agents/plugins/registry.yaml` | `dots sync` (or `plugin-sync`) |
| Claude-native plugin | `claude/plugins/registry.yaml` | `dots sync` |
| Cursor plugin | `cursor/plugins/local/<name>/` | `dots sync` |
| Package | `packages/packages.yaml` | `dots sync` |
| Profile | `profiles/<name>/profile.yaml` | `dots profile install` / `launch` |
| omp (oh-my-pi) config | `chezmoi/.chezmoidata/omp.yaml` | `dots sync` |

**`dots sync` before committing.** The prek pre-commit hook blocks commits when `~/.claude/` is out of sync with the repo. See [[operations/dev-environment]].

**`just check` is the single exit gate.** Before declaring any code change done — and always before commit/push — run `just check` (lint + test + smoke) and confirm it exits 0. It is the exact gate CI runs, so green locally means the `lint` and `test` jobs pass; never accept a pending CI run as a substitute for running it. If a gate tool is missing locally (e.g. `ruff`), say so and name the unrun leg rather than claiming green. Run `dots sync` first when registry / skill / agent / doc source changed.

**Shell functions need tests.** New shell logic goes into a named function in a sourced lib (`.sync-lib.sh`, `chezmoi/lib/*.sh`, …), exercised by a `tests/<area>.bats` file (mock externals via `$PATH`). `.sync` scripts stay thin: parse args, source lib, dispatch. Add new test files to `tests/run-tests.sh`. Rationale: [[operations/sync-and-chezmoi]].

**chezmoi hard rules** (detail: [[operations/sync-and-chezmoi]]):

1. Never commit plaintext secrets to `chezmoi/` — use `encrypted_` or `{{ env }}` / `{{ onepasswordRead }}`.
2. Never edit a chezmoi-managed target directly — use `chezmoi edit ~/.gitconfig` so templating round-trips.
3. `chezmoi --source $DOTFILES/chezmoi diff` before applying template changes.
4. `prompt*` template funcs belong only in `.chezmoi.toml.tmpl` (a `prompt*` in a dotfile template re-prompts every apply).

**`bin/` runs live from the clone** (`export PATH="$DOTFILES_DIR/bin:$PATH"` in `zsh/core.zsh`) — edits to `dots` / `gh-*` are immediate, no `chezmoi apply`.

## Gotchas

- macOS-oriented paths; the shell is in vi-mode.
- `zsh/` files source in `zshrc` order — a new file needs a `zshrc` source line at the right point (completions must load before `fzf.zsh`).
- Reference docs go in `reference/` (gitignored, not synced).
- `git commit --no-verify` only for rare temporary prek overrides (see `prek.toml`).
- Prefix shell commands with `rtk` (token-filtering proxy; a hook auto-rewrites them anyway). Full reference: `~/.claude/RTK.md` or `rtk --help`.
