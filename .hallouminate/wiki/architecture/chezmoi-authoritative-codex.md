# Codex is chezmoi-authoritative

`~/.codex` converges on `dots sync` from `chezmoi/.chezmoidata/codex.yaml` plus
`chezmoi/private_dot_codex/`, the same regime Claude got in #367. Additions *and*
removals propagate. This closes the freeze that AGENTS.md recorded as "other
harnesses remain frozen pending migration".

## Why the freeze happened

PR #367 (`414e5c8`, 2026-07-02) made chezmoi authoritative for global Claude config
and deleted `run_onchange_after_install-base-profile.sh.tmpl` — the only leg that
rendered Codex — stating the intent as "retire the ap/agent-profile tool from all
live installs". Claude got a chezmoi replacement; Codex got none. The last render
was 2026-07-01 07:20:14, and `hooks.json`, `hooks/*.sh`, and 17 `agents/*.toml`
sat frozen at that instant while 12 commits landed against `agents/registry.yaml`.

Three fossils accumulated, each from a different era:

- **Duplicate hooks.** Era-1's inline `[[hooks.*]]` blocks in `config.toml` (from
  the retired `agents/hooks/sync.sh`) coexisted with Era-2's `hooks.json`. Codex
  merges both sources, so `git-guard`, `sensitive-file-guard`, and
  `session-start-cheese-flair` each fired twice per session.
- **Orphan `Stop` hook** pointing at `jmux-attention.sh`, removed from the repo by
  #398 but pinned by the frozen render.
- **Undead `[mcp_servers.serena]`**, which #512 removed from the repo but
  `install-codex.sh` could never evict — it only ever backfilled *missing* keys.
  It kept littering repos with `.serena/` dirs.

## The split that makes this work

`~/.codex/config.toml` cannot be a plain managed file: the CLI writes its own
runtime state into the same file the repo wants to own.

| Half | Keys | Mechanism |
|---|---|---|
| Repo-authored | `mcp_servers`, root scalars, `sandbox_workspace_write`, `tui.input_mode` | `modify_private_config.toml` merge |
| Codex-CLI runtime state | `projects.*` trust, `hooks.state.*` approval hashes, `marketplaces`, `plugins`, `tui.model_availability_nux` | preserved untouched |

So the merge is **preserve-by-default** — the inverse of
`dot_claude/modify_settings.json`, which wipes unmanaged keys and halts on unknown
ones. Clobbering Codex's state would re-prompt every hook approval and forget every
trusted project. `tui` is deep-merged so `model_availability_nux` survives beside
the declared `input_mode`.

`mcp_servers` is the single exception: **replaced wholesale**, so deleting a server
from the registry evicts it from the live file. That is the serena fix.

The merge also removes only legacy `[[hooks.<event>]]` entries whose first command
points to a Codex-harnessed hook basename in `agents/hooks/registry.yaml`; it keeps
`hooks.state` trust hashes and user-authored hook blocks.[^1]

Everything else (`exact_agents`, `exact_hooks`, `exact_lib`, `exact_reference`) is
an `exact_` tree, so apply deletes what the registry no longer selects — verified
by the stale `lib/tool-reroute.js` and `lib/reroute/` disappearing on first sync.

## Gotchas worth remembering

- **chezmoi attribute order**: `modify_private_config.toml`, *not*
  `private_modify_config.toml`. With the attributes reversed chezmoi silently stops
  recognising the file as a modify script — `chezmoi managed` drops
  `.codex/config.toml` entirely and nothing warns you.
- **`private_` is required** on both the dir and the script, or apply relaxes
  `~/.codex` from `700` to `775` and `config.toml` from `600` to `664`. That file
  sits beside `auth.json`.
- **Absolute hook commands.** Codex runs hook commands from the session cwd, so
  `hooks.json` bakes absolute paths. Keeping the per-event ordering stable
  (`git-guard` at index 0, `sensitive-file-guard` at 1) preserves the existing
  `hooks.state` trust hashes, so a migration causes no re-approval storm.
- **No `env` blocks in `codex.yaml`.** Codex is terminal-launched and its MCP
  children inherit the exported shell env, so neither a secret nor a `${VAR}`
  placeholder is written to disk — see [[mcp-secret-handling]].
- **`yq` writes TOML** (v4.53.3) and round-trips quoted keys containing dots,
  colons, and slashes; it also hoists root scalars above table headers, so JSON key
  order cannot produce invalid TOML. It does not preserve comments.
- **`tool-reroute` is claude-only** (`5f78a0f`, one day after the frozen render),
  which is why live Codex ran it for a month after the decision. Codex therefore
  has no `rtk` command rewriting.

## `agent_is_read_only` was inverted for tilth writers

Migrating surfaced a latent bug in `agent_profile/shared.py`: the predicate returned
read-only when `disallowedTools` banned *any* built-in writer, even with
`mcp__tilth__tilth_write` retained — contrary to its own docstring. Codex sandboxes
by capability (`sandbox_mode`), so shipping that would have sandboxed `coder`,
`researcher`, `reviewer`, `generalist`, and `explorer` out of their own jobs.

Read-only now means **no write tool remains reachable**: every entry of
`_WRITE_TOOLS` is banned by `disallowedTools` or excluded by a `tools` whitelist.

The five read-only agents (`fromage-age-arch`, `fromage-age-history`,
`fromage-secaudit`, `ghostbuster`, `nih-scanner`) deny every `_WRITE_TOOLS` entry,
so their rendered Codex agents carry `sandbox_mode = "read-only"`.[^2] Other
agents retain a required write path, including `explorer`'s out-of-context
`.cheese/explore/<slug>.md` artifact.

## Scope

Deliberately excluded: `~/.codex/skills` (empty — skills resolve via the
cross-harness `~/.agents/skills`, shared with still-frozen harnesses) and
`rules/` (no repo source; generated by `ap` from permissions data). opencode,
Cursor, and Copilot remain frozen.

See also [[codex-first-class-review]], [[codex-hooks-schema]],
[[sync-and-chezmoi]], [[config-drift]].

[^1]: chezmoi/private_dot_codex/modify_private_config.toml; agents/hooks/registry.yaml
[^2]: agents/registry.yaml; agent-profile/agent_profile/shared.py:63-108; tests/sync-codex-sources.bats
