# Config Drift & Self-Heal

Why live harness config on a machine can disagree with what `ap` renders from
the registries, how to tell the kinds of drift apart, and what heals each.
This is the *why* behind the `/harness-doctor` skill and the renderer-level
self-heal (legacy hooks + dropped MCPs).

## The root cause: seed-once / merged files nothing prunes

Most live config is fully owned by `ap` — it rewrites the plugin tree,
claude's plugin `.mcp.json`, etc. wholesale on every `dots sync`. Drift lives
in the files `ap` **merges into** rather than overwrites: chezmoi `create_`
seeds and user-owned configs it reads-modifies-writes. The ones that bite:

- `~/.claude/settings.json` — `ap install global` only jq-*merges*
  `enabledPlugins` + `extraKnownMarketplaces` (`claude.py:_merge_root_settings`),
  preserving every other key.
- `~/.codex/config.toml`, `~/.config/opencode/opencode.json`,
  `~/.cursor/mcp.json`, `~/.copilot/mcp-config.json` — each seeded/user-owned;
  `ap` merges MCP entries into them per render.
- `~/.claude.json` — claude user-scope MCP registrations (`claude mcp add`).

That merge-not-overwrite asymmetry is the drift engine. Two leftover kinds:

**Legacy hooks.** Before the `ap` migration (commit **#217**, `feat(ap): add
global profile + migrate settings.json to chezmoi seed`), the retired
`agents/hooks/sync.sh` jq/yq-merged the hook registry **directly into** those
user files — `settings.json` for Claude, `[[hooks.*]]` in `config.toml` for
Codex. The migration moved hook wiring into the per-harness render targets
(Claude's plugin `plugin.json`; Codex's `hooks.json`), but nothing removed the
old copies. They linger as **dead hooks** (script path deleted → exit 127 every
session start, e.g. the pre-ap cheese-flair entry) or **double-fired hooks**
(byte-identical to a now-managed hook like `moshi-hook`; the harness loads both
sources and fires twice).

**Dropped MCPs.** Remove an MCP from `agents/mcp/registry.yaml` and the next
render simply stops writing it — but the entry a *prior* render merged into the
files above is never removed, so it lingers indefinitely.

## Three classes of drift

| Class | Signature | Action |
|---|---|---|
| **Stale remnant** | Live, absent from the `ap` render, AND git history shows the repo moved this responsibility elsewhere (legacy hook) or dropped it from a registry (MCP). | Prune (self-heal). |
| **Dotfiles bug** | The repo's own source is wrong (registry → missing script, invalid hook `event`, required MCP `${VAR}` not marked `optional`, wiki index won't rebuild). | Open a gh issue. |
| **Expected local** | Live-only, no repo provenance — a personal hook, an extra permission, the tmux Stop hook, the JS guards under `~/.claude/hooks/`, a hand-added MCP. | Leave alone. |

The Claude-specific JS guards (`bash-guard.js`, `write-guard.js`, …), `rtk`,
and any tmux hook are **settings-only and legit** — not managed by any render
target, so they are *not* drift even though they live in `settings.json`.

## The heal lives in the renderers — all harnesses alike

Self-heal is a renderer responsibility, run on every `ap install` — not a
bolt-on chezmoi script. Two reconcile passes:

### Legacy hooks (per-renderer, keyed off what it just wired)

- **claude** — `claude.py:_clean_legacy_settings_hooks` builds a per-event
  signature set from the hooks it wired into `plugin.json` — a script basename
  (for `${CLAUDE_PLUGIN_ROOT}/hooks/<base>`) or the full command string (moshi)
  — and drops any `settings.json` hook whose command duplicates one, pruning at
  the inner-hook level so a user command sharing a block survives, then pruning
  emptied events.
- **codex** — `codex.py:_clean_legacy_config_toml_hooks` does the equivalent
  for `[[hooks.*]]` blocks in `config.toml`, matching managed basenames per
  event.

Keyed off the hooks the renderer *just produced*, so it self-extends (add a
registry hook → it renders → stale copies auto-strip next sync) and fails safe
(no managed hooks → no signatures → never strips blind). opencode/cursor/
copilot receive no cross-harness registry hooks, so there's no hook drift there.

### Dropped MCPs (install-level diff → per-renderer `prune_mcps`)

`cli.py:_reconcile_dropped_mcps` snapshots the prior resolved manifest (cached
as `merged_json` in `manifest.json`) before the render loop overwrites it,
diffs it against the current manifest, and for each in-scope harness calls
`renderer.prune_mcps(dropped_manifest, target)` — where `dropped_manifest`
carries *only* the servers that fell out of the registry. Each renderer
implements `prune_mcps` (the `Renderer` protocol) by reusing its own MCP-only
removal:

- **codex/opencode/cursor/copilot** — delegate to their existing MCP-only
  `clean` path (the `dropped_manifest` has empty non-MCP fields, so clean's
  other passes no-op); the dropped server is popped from the merged file.
- **claude** — plugin `.mcp.json` is whole-file (no drift); only user-scope
  registrations persist, so `prune_mcps` calls `_unregister_user_mcps` to
  `claude mcp remove` exactly the dropped servers. No-op for plugin scope.

Fires only when a prior install exists AND something dropped, so fresh renders
stay byte-identical (golden-test safe). User-authored MCP entries survive —
only servers a prior render wrote (still named in the prior manifest) are
evicted.

So the heal for **both** classes is just **`dots sync`** (which runs
`ap install global`). Why renderer-level and not a chezmoi script: it's where
codex already put the hook cleanup, it runs in the single `ap install` path (no
`run_onchange` ordering hacks), and it's unit-tested in-process
(`tests/test_claude_legacy_hook_cleanup.py`, `test_codex_legacy_hook_cleanup.py`,
`test_mcp_reconcile.py`).

## Known drift pattern: yq-appended keys absorbed by codex auto-sections

**Symptom**: `model_instructions_file` duplicated inside `[tui.model_availability_nux]`
in `~/.codex/config.toml`; preamble silently not loading.

**Why it happens**: `chezmoi/lib/install-prompts.sh` uses `yq -i '.model_instructions_file = ...'`
which appends the key at the end of the file. Codex periodically auto-adds
`[tui.model_availability_nux]` (UI state) near the end, absorbing the appended
key into that section. On the next `dots sync`, yq reads `.model_instructions_file`
at root, gets "" (it's inside tui section), writes another copy at end → duplicate
inside the section. Neither copy is read by codex as the root-level key it expects.

**Fix**: Move `model_instructions_file` before the first `[section]` header in
`config.toml` (line 1 works). The guard in `install-prompts.sh` will then find
it correctly and skip re-writing. See [#262](https://github.com/paulnsorensen/dotfiles/issues/262)
for the permanent fix (use tomlkit or sed-prepend instead of yq-append).

## Known drift pattern: copilot MCPs not managed by `ap` renderer

Copilot's `mcp-config.json` is managed by the **chezmoi template**
(`chezmoi/private_dot_copilot/mcp-config.json.tmpl`), not by `ap install`.
`_COPILOT_MCP_DEFAULT = ("claude", "codex")` in `renderers/copilot.py` means
no registry MCP without an explicit `harnesses: [copilot]` entry is rendered
into copilot. The template is the single source of truth for what MCPs copilot
gets. When the registry adds a new MCP (e.g. `hallouminate`, `serena`), the
chezmoi template must be manually updated to match.

## Gotcha: index drift is its own drift class

The hallouminate wiki index (LanceDB) is derived from the markdown on disk. If
`ground` errors with `missing column chunk_id` (or similar), the index is stale
vs the schema — run `hallouminate index` to rebuild. A doctor run should treat
a non-rebuildable index as a dotfiles bug, not just retry.

See [[agent-profile]] for the `ap` render/install model and [[../harnesses/claude]]
for where each Claude config surface lives.
