# Pi coding agent

Upstream Pi is a first-class global harness sibling, not an `ap` renderer and not an OMP alias. `dots sync` installs the pinned CLI, authors `~/.pi/agent/`, assembles shared skills and extensions, and reconciles Pi packages. Pi keeps its own auth, trust, sessions, and package stores.

## Ownership boundary

`chezmoi/.chezmoidata/pi.yaml` is the registry for the managed settings and local-model catalog:

- `chezmoi/dot_pi/private_agent/modify_settings.json` authors `~/.pi/agent/settings.json` wholesale. It preserves only Pi's `lastChangelogVersion` machine-state key and halts on unknown live key paths instead of silently deleting a new upstream setting.
- `chezmoi/dot_pi/private_agent/models.json.tmpl` authors `~/.pi/agent/models.json`; the `localLLM` machine flag controls whether the shared local provider catalog is present.
- `chezmoi/dot_pi/private_agent/mcp.json` is the Pi MCP-adapter registry. Tilth is exposed as direct tools; Context7 and Tavily use the secret proxy; Milknado and Hallouminate remain ordinary MCP servers.
- `~/.pi/agent/auth.json`, `trust.json`, `sessions/`, `npm/`, and `git/` are Pi-owned runtime state and are not exact-managed by chezmoi.

This split intentionally differs from OMP's `config.yml`/`models.yml` schema. Sharing payloads does not imply sharing configuration or state.

## Resource assembly

`sync_pi_chezmoi_sources` in `.sync-lib.sh` rebuilds the managed resource payload before chezmoi applies:

- `exact_skills/` from the selected local skill list in `claude.yaml` plus external sources whose `harnesses:` filter includes `pi`;
- `extensions/` from the shared OMP-family `rtk.ts` and `cheese-flair.ts` extensions;
- `themes/` from the shared `chocolate-donut.json` theme.

Skills are exact because the registry is the complete selection. Extensions and themes are merge-managed so package- or application-installed Pi resources survive `dots sync`.

Pi discovers these resources under `~/.pi/agent/` independently of OMP. The common files stay single-source in `dot_omp/private_agent/`; the assembler copies them into Pi's deployment tree so neither live harness depends on the other's config directory.

## Instructions and system prompt

`run_onchange_after_install-agents-doc.sh.tmpl` installs `agents/AGENTS.md` as `~/.pi/agent/AGENTS.md`. Pi loads that global context file natively.

`chezmoi/dot_pi/private_agent/APPEND_SYSTEM.md` is Pi-specific standing guidance. The `pi()` wrapper in `zsh/aliases.zsh` reads it and passes its contents through upstream Pi's `--append-system-prompt <text>` flag; `PI_CODING_AGENT_DIR` selects a non-default native config root. Package/config/auth subcommands and non-chat inspection flags bypass the addendum because Pi dispatches subcommands from the first argument.

## Packages and CLI pin

`packages/packages.yaml` pins `@earendil-works/pi-coding-agent` and installs it with `--ignore-scripts`. The same registry path is exercised by `packages/sync.sh`; pinned npm packages reconverge even outside upgrade mode.

The `packages` array in `pi.yaml` pins `pi-mcp-adapter` and `pi-subagents`. After chezmoi applies settings, `.sync` calls `sync_pi_packages`, which runs `pi update --extensions`; Pi installs missing configured packages and leaves versioned npm specs pinned.

## Capability map

| Capability | Official doc | This repo |
|---|---|---|
| Settings and trust | [settings.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/settings.md) | `pi.yaml` + `modify_settings.json` |
| Providers and local models | [models.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/models.md) | `models.json.tmpl` |
| Global context and system prompt | [README: Context Files](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/README.md#context-files) | `agents/AGENTS.md` + the `pi()` addendum wrapper |
| Skills | [skills.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md) | `sync_pi_chezmoi_sources` → `exact_skills/` |
| Extensions and hooks | [extensions.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) | shared `rtk.ts` and `cheese-flair.ts` |
| Packages | [packages.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/packages.md) | `pi.yaml` `settings.packages` + `sync_pi_packages` |
| MCP | [extensions.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/extensions.md) | `pi-mcp-adapter` + `mcp.json` |
| Sub-agents | [packages.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/packages.md) | pinned `pi-subagents` package |

## Verification seam

`tests/pi-config.bats` proves registry rendering, machine-state preservation, unknown-key failure, complete chezmoi wiring, and the pinned CLI install flags. `tests/chezmoi-wiring.bats` exercises the source-assembly call in the deploy path; `tests/packages.bats` covers npm flag propagation and exact-version convergence.

Related: [[omp]], [[../architecture/agent-profile]], [[../operations/sync-and-chezmoi]].
