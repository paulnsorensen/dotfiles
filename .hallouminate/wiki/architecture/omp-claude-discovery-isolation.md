# OMP Claude Discovery Isolation

Oh My Pi has two distinct Claude isolation levers: provider discovery isolation inside OMP, and launch-time settings isolation when `ap` starts Claude Code. `disabledProviders: [claude]` is the documented way to express “drop Claude discovery,” but checked OMP startup code currently initializes provider filtering after the first settings-provider scan, so it does **not** guarantee that Claude settings files are never read during startup.

## OMP discovery isolation

OMP's `disabledProviders` setting accepts discovery provider ids as well as model provider ids. Disabling the `claude` discovery provider removes the whole Claude config source: context files, MCP servers, slash commands, skills, hooks, tools, prompts, and settings. This is provider-wide, not settings-only (`/home/paul/Dev/oh-my-pi/docs/context-files.md:179-195`, `/home/paul/Dev/oh-my-pi/docs/settings.md:253-264`).

```yaml
# ~/.omp/agent/config.yml, <repo>/.omp/config.yml, or a --config overlay
disabledProviders:
  - claude
```

Use the path-scoped form when one checkout should avoid Claude-discovered config but global OMP behavior should stay unchanged:

```yaml
disabledProviders:
  - path: /absolute/path/to/repo
    providers:
      - claude
```

Path-scoped entries match the cwd or descendants and accept `path|paths|pathPrefix|pathPrefixes` plus `providers|values|items` (`/home/paul/Dev/oh-my-pi/docs/settings.md:221-251`). OMP arrays replace across settings layers; if a project config sets `disabledProviders`, it must include the complete desired list, not just the extra entry (`/home/paul/Dev/oh-my-pi/docs/context-files.md:207-209`, `/home/paul/Dev/oh-my-pi/docs/settings.md:264-268`).

## Startup caveat

The documented provider disable is not currently early enough to prevent the initial settings-source read:

1. CLI and SDK startup call `Settings.init()` first (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/main.ts:1022-1053`, `/home/paul/Dev/oh-my-pi/packages/coding-agent/src/sdk.ts:1125-1128`).
2. `Settings.init()` immediately starts `#load()` (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings.ts:280-285`).
3. `#load()` starts `#loadProjectSettings()` before global config, project config, overlays, and merged settings are rebuilt (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings.ts:652-669`).
4. `#loadProjectSettings()` calls `loadCapability(settingsCapability.id, { cwd })` with no provider filter (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings.ts:704-713`).
5. Provider filtering reads the in-memory disabled-provider set, but that set is populated later by `initializeWithSettings()` (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/capability/index.ts:210-240`, `/home/paul/Dev/oh-my-pi/packages/coding-agent/src/capability/index.ts:251-259`).
6. The Claude settings provider reads both `~/.claude/settings.json` and `<cwd>/.claude/settings.json` (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/discovery/claude.ts:468-505`, `/home/paul/Dev/oh-my-pi/packages/coding-agent/src/discovery/claude.ts:570-575`).

Net: `disabledProviders: [claude]` still documents and applies the desired provider policy after initialization, but it is not a hard “never read Claude settings files” guarantee in the checked startup path.

## What native `.omp/AGENTS.md` does and does not do

Native `.omp/AGENTS.md` has higher priority than Claude's context provider at the same scope, so it can shadow a `.claude/CLAUDE.md` context file. It does **not** disable the Claude provider's other contributions. If the goal is “no Claude settings/MCP/hooks/tools/prompts from discovery,” context shadowing is insufficient; use provider disabling and fix the startup ordering if zero-read isolation is required (`/home/paul/Dev/oh-my-pi/docs/context-files.md:188-195`).

## Claude launched through `ap`

`dots profile launch claude <profile>` uses the repo's isolated profile machinery, not OMP provider discovery. For `isolated: true` Claude profiles, `agent-profile/agent_profile/overlay.py` builds a closed launch:

- `--strict-mcp-config --mcp-config <tmp>` (`agent-profile/agent_profile/overlay.py:275-276`)
- `--setting-sources ""` to strip inherited user/project/local settings (`agent-profile/agent_profile/overlay.py:278-279`)
- `--tools <csv>` when the profile declares a whitelist (`agent-profile/agent_profile/overlay.py:281-282`)
- `--append-system-prompt-file <profile file>` when declared (`agent-profile/agent_profile/overlay.py:284-290`)
- `--settings <tmp settings.json>` for profile permissions/plugins (`agent-profile/agent_profile/overlay.py:292-294`)
- `--plugin-dir <tmp plugin>` so profile skills still load even with `--setting-sources ""` (`agent-profile/agent_profile/overlay.py:296-301`)

`zsh/claude.zsh:149-156` documents this as the replacement for the retired `ccp` launcher. See [[../harnesses/claude]] for the Claude-specific closed-world matrix and [[agent-profile]] for cross-harness differences.

## Absence check: settings-only Claude disable

Checked candidates:

| Candidate | Result |
|---|---|
| `disabledProviders: [claude]` | Documented whole-provider disable; too late to prevent the first settings-provider read in checked startup code. |
| Native `.omp/AGENTS.md` | Shadows same-scope context only; not a provider-source disable. |
| Skills/slash-command feature toggles | Claude-specific toggles exist for skills and commands, not for settings, context files, hooks, tools, MCP servers, or system prompts (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings-schema.ts:4197-4235`, `/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings-schema.ts:5069-5083`). |
| Capability provider filters | Internal `loadCapability()` supports `providers`/`excludeProviders`, but the settings manager does not pass them (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/capability/index.ts:213-219`, `/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings.ts:704-713`). |
| Claude CLI `--setting-sources ""` | Launch-time Claude setting-source filter; unrelated to OMP discovery. |

No checked OMP source documented a user-facing “keep Claude discovery enabled but suppress only Claude settings” switch. Treat that as not found in OMP docs/code checked on 2026-07-01.

_Source: OMP/Claude settings isolation research plus `/home/paul/Dev/oh-my-pi` code read · Updated: 2026-07-01 · Supersedes: earlier docs-only belief that `disabledProviders: [claude]` prevents all Claude settings reads._
