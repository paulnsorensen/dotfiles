# Config Drift & Self-Heal

Why live harness config on a machine can disagree with what `ap` renders from
the registries, how to tell the kinds of drift apart, and what heals each.
This is the *why* behind the `/harness-doctor` skill and the renderer-level
legacy-hook cleanup.

## The root cause: seed-once files nothing prunes

Most live config is fully owned by `ap` — it rewrites the plugin tree,
`.mcp.json`, codex `[mcp_servers]`, etc. on every `dots sync`. But a few files
are chezmoi `create_` seeds or otherwise user-owned: written once, then never
overwritten or pruned. The two that bite:

- `~/.claude/settings.json` — `ap install global` only jq-*merges*
  `enabledPlugins` + `extraKnownMarketplaces` into it (`claude.py:_merge_root_settings`),
  preserving every other key.
- `~/.codex/config.toml` — seeded once, then user-owned; `ap` merges
  `[mcp_servers]` into it.

That asymmetry is the drift engine. Before the `ap` migration (commit **#217**,
`feat(ap): add global profile + migrate settings.json to chezmoi seed`), the
retired `agents/hooks/sync.sh` jq/yq-merged the hook registry **directly into
those user files** — `settings.json` for Claude, `[[hooks.*]]` in `config.toml`
for Codex. The migration moved hook wiring into the per-harness render targets
(Claude's plugin tree `plugin.json`; Codex's `hooks.json`) — but nothing
removed the old copies. They linger as:

- **Dead hooks** — the script path no longer exists. The pre-ap cheese-flair
  hook (`bash "$HOME/.claude/hooks/session-start-cheese-flair.sh"`) points at a
  file deleted when hooks moved into the plugin; it fails (exit 127) silently
  on every session start.
- **Double-fired hooks** — byte-identical to a now-managed hook (e.g.
  `moshi-hook`), and the harness loads both sources at once, so the event fires
  twice (duplicate phone notifications, etc.).

## Three classes of drift

| Class | Signature | Action |
|---|---|---|
| **Stale remnant** | Live, absent from the `ap` render, AND git history shows the repo moved this responsibility elsewhere. | Prune (self-heal). |
| **Dotfiles bug** | The repo's own source is wrong (registry → missing script, invalid hook `event`, required MCP `${VAR}` not marked `optional`, wiki index won't rebuild). | Open a gh issue. |
| **Expected local** | Live-only, no repo provenance — a personal hook, an extra permission, the tmux Stop hook, the JS guards under `~/.claude/hooks/`. | Leave alone. |

The Claude-specific JS guards (`bash-guard.js`, `write-guard.js`, …), `rtk`,
and any tmux hook are **settings-only and legit** — not managed by any render
target, so they are *not* drift even though they live in `settings.json`.

## The heal lives in the renderers — all harnesses alike

The legacy-hook cleanup is a renderer responsibility, run on every `ap install`
— not a bolt-on chezmoi script. Each renderer prunes its *own* harness's
pre-ap leftovers, keyed off the hooks it just wired into that harness's render
target:

- **claude** — `agent_profile/renderers/claude.py:_clean_legacy_settings_hooks`
  builds a per-event signature set from the hooks it wired into `plugin.json` —
  a script basename (for `${CLAUDE_PLUGIN_ROOT}/hooks/<base>`) or the full
  command string (for command-type hooks like moshi) — and drops any
  `settings.json` hook whose command duplicates one, pruning at the inner-hook
  level so a user command sharing a block survives, then pruning emptied events.
- **codex** — `agent_profile/renderers/codex.py:_clean_legacy_config_toml_hooks`
  does the equivalent for `[[hooks.*]]` blocks in `config.toml`, matching
  managed script basenames per event.

Because each cleanup is keyed off the hooks the renderer *just produced*, it
self-extends: add a hook to `agents/hooks/registry.yaml` → it renders → the
matching renderer auto-strips any stale user-file copy on the next sync. It
fails safe — no managed hooks means no signatures, so it can never strip when
it doesn't know what's managed.

So the heal is simply **`dots sync`** (which runs `ap install global`).
opencode/cursor/copilot don't receive the cross-harness `agents/hooks/`
registry hooks (their cursor/copilot guard hooks ship via chezmoi separately),
so there is no registry-hook drift to heal there — the "all harnesses alike"
coverage is complete with claude + codex both self-cleaning.

Why renderer-level and not a chezmoi heal script: it's where codex already put
it, it runs as part of the single `ap install` path (no `run_onchange`
ordering hacks), and it's unit-tested in-process
(`tests/test_claude_legacy_hook_cleanup.py`, `tests/test_codex_legacy_hook_cleanup.py`).

## Gotcha: index drift is its own drift class

The hallouminate wiki index (LanceDB) is derived from the markdown on disk. If
`ground` errors with `missing column chunk_id` (or similar), the index is stale
vs the schema — run `hallouminate index` to rebuild. A doctor run should treat
a non-rebuildable index as a dotfiles bug, not just retry.

See [[agent-profile]] for the `ap` render/install model and [[../harnesses/claude]]
for where each Claude config surface lives.
