# Config Drift & Self-Heal

Why live harness config on a machine can disagree with what `ap` renders from
the registries, how to tell the kinds of drift apart, and what heals each.
This is the *why* behind the `/harness-doctor` skill and the renderer-level
self-heal (legacy hooks + dropped MCPs).

## Current state: global settings disconnected

Non-isolated `ap install global` no longer read-modify-writes harness-global settings files. The live global config surfaces — `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.config/opencode/opencode.json`, `~/.cursor/mcp.json`, `~/.copilot/mcp-config.json`, and `~/.config/crush/crush.json` — are now chezmoi/user-owned surfaces. `ap` renders generated artifacts (plugin trees, agents, hooks, skills) and isolated-profile settings only; `agent-profile/agent_profile/compiled_types.py:17-20` keeps merged settings out of compiled manifests.

Historical drift still matters because older apply-state and older live files may contain entries that `ap` used to merge. `ap apply-compiled` now preserves those disconnected legacy paths if a prior state file still lists them, so migration removes ownership without deleting a live user settings file (`agent-profile/agent_profile/merged_settings_preservation.py:31-42`, `agent-profile/agent_profile/apply_compiled.py:151-171`).

The old merge-not-overwrite asymmetry caused two leftover kinds:

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

## Historical self-heal vs current ownership

Renderer-level self-heal still describes how stale registry-managed entries should be removed **when a renderer owns that merged surface** (mostly isolated profiles and historical installs). It is no longer a blanket guarantee that `dots sync` prunes every live global settings file, because non-isolated global installs do not mutate those files anymore.

- **Legacy hooks** — Claude/Codex historical settings/config hooks should be removed from the live settings source that now owns the file. The old renderer cleanup logic was keyed off hooks it just wired, so it failed safe; after the global settings disconnect, treat remaining global hook drift as a chezmoi/live-settings migration item.
- **Dropped MCPs** — `_reconcile_dropped_mcps` still expresses the right provenance rule: remove only servers a prior render wrote, never unrelated user MCPs. For disconnected global surfaces, the cleanup belongs to the new owner of that file (chezmoi template/modify script or manual CLI), not a blind renderer pass.

The migration invariant is stricter than the old self-heal rule: removing `ap` ownership must not delete live global settings. `tests/test_compile_apply_preservation.py::test_apply_does_not_delete_disconnected_global_settings_from_prior_state` pins that.

## Known drift pattern: yq-appended keys absorbed by codex auto-sections

**Symptom**: `model_instructions_file` duplicated inside a codex-auto-added section
(typically `[tui.model_availability_nux]` or `[plugins.\"github@openai-curated\"]`) in
`~/.codex/config.toml`; preamble silently not loading.

**Why it happens**: `chezmoi/lib/install-prompts.sh` uses `yq -i '.model_instructions_file = ...'`
which appends the key at the end of the file. Codex periodically auto-appends sections
(`[tui.model_availability_nux]` for UI state, `[plugins.\"github@openai-curated\"]` for plugin
config) near the end of the file, absorbing the trailing key into whichever section got
appended last. On the next `dots sync`, yq reads `.model_instructions_file` at root, gets
"" (it's inside a section), writes another copy at end → that copy gets absorbed into the
same section too → two duplicates, neither at root level. Neither is read by codex as the
root-level key it expects.

**Fix**: Move `model_instructions_file` before the first `[section]` header in
`config.toml` (line 1 works). The guard in `install-prompts.sh` will then find
it correctly and skip re-writing. See [#262](https://github.com/paulnsorensen/dotfiles/issues/262)
for the permanent fix (use tomlkit or sed-prepend instead of yq-append).

## Known drift pattern: copilot MCP template lags behind registry

Copilot's `mcp-config.json` is managed by the **chezmoi template**
(`chezmoi/private_dot_copilot/mcp-config.json.tmpl`), not by `ap install`.
`_COPILOT_MCP_DEFAULT = ("claude", "codex")` in `renderers/copilot.py` means
no registry MCP without an explicit `harnesses: [copilot]` entry is rendered
into copilot. The template is the single source of truth for what MCPs copilot
gets. When a registry MCP's command/args changes, the template must be manually
updated to match — the `ap` renderer won't touch copilot's merged files.

### serena-mux → stdio serena (current gap)

**Symptom**: Copilot's serena entry uses `serena-mux` with `SERENA_MUX_HARNESS`,
but serena-mux was retired and the registry now uses direct stdio `serena`.

**Root cause**: serena-mux was retired in commit 611f9e1 (Retire serena-mux,
switch to stdio serena) — 472 orphaned daemons, 35.5GB RSS OOM at 6% reuse.
The registry entry was updated to direct `serena` stdio with per-harness
`--context` args, but `chezmoi/private_dot_copilot/mcp-config.json.tmpl:72-76`
was never updated.

**Detection**: Compare the serena entry in `~/.copilot/mcp-config.json` against
the registry: the template still emits `serena-mux` when the registry has used
direct `serena` since 611f9e1.

**Fix**: Update the template to match the registry pattern. See
[#293](https://github.com/paulnsorensen/dotfiles/issues/293).

### Historical: milknado standalone MCP → Claude plugin

milknado was added to the registry as a standalone MCP in #274, then refactored
into a Claude-only plugin in 8b829c0 (drop standalone MCP, give milknado its
own Claude plugin). The copilot template never had a milknado entry, so this
was never a real gap — the wiki note "milknado is missing from the copilot
template" was only relevant during the brief window between #274 and 8b829c0
when it was a registry MCP.

## Known drift pattern: MCPs no longer projected to a harness

**Symptom**: An MCP remains in a merged-file target even after the current render no longer projects it to that harness — for example a Copilot `mcp-config.json` entry for `tilth`, `context7`, `tavily`, or `serena` after Copilot narrowed to explicit `harnesses: [copilot]` entries.[^copilot-stale-mcp]

**Why it happens**: merged files are read-modify-write surfaces. A current render writes/updates entries that still project to the harness, but a stale entry can persist when the old source was historical template drift or when prior manifest ownership did not prove that the harness once received the MCP.

**Fix**: `_reconcile_dropped_mcps` handles normal registry drops and `harnesses: []` changes by diffing per-harness projections, not the global `manifest.mcps` set.[^reconcile-projection] Copilot additionally prunes same-name registry MCPs that are present in `.copilot/mcp-config.json` but no longer project to Copilot during `_write_mcp`, preserving unrelated user MCPs.[^copilot-prune-nonprojected]

**Detection**: Compare the live merged file's server names against the current renderer projection. Same-name registry entries that are live-only are stale; unrelated names are expected-local.

[^copilot-stale-mcp]: harness-doctor run on 2026-06-24 found Copilot live-only `context7`, `serena`, `tavily`, and `tilth` while the current render produced only `hallouminate` and `milknado`.
[^reconcile-projection]: agent-profile/agent_profile/cli.py:418-473; agent-profile/tests/test_mcp_reconcile.py:test_mcp_scoped_to_no_harnesses_is_pruned
[^copilot-prune-nonprojected]: agent-profile/agent_profile/renderers/copilot.py:263-312; agent-profile/tests/test_renderer_copilot.py:test_mcp_prunes_registry_servers_no_longer_projected_to_copilot

## Known drift pattern: settings.json hook-runner command references non-existent JS file

**Symptom**: `hook-runner.js` emits stderr noise on every Bash tool call:
`hook-runner: failed to load git-guard.js: Cannot find module ...`

**Why it happens**: `~/.claude/settings.json` is a `create_` chezmoi seed —
written once and then user-owned. If a guard script name is manually added to
a hook-runner command (e.g. `bash-guard.js git-guard.js`) but the corresponding
`~/.claude/hooks/<name>.js` file is never deployed, the runner fails-open (logs
the error, continues with loaded hooks) every Bash call. The renderer's
`_clean_legacy_settings_hooks` won't catch it — the command doesn't duplicate
any plugin-managed hook's basename or exact command string.

**Why git-guard.js in particular**: The git-guard PreToolUse hook was
implemented as a **shell hook** in the plugin tree (`git-guard.sh`), not as a
settings-managed JS hook. The `agents/lib/git-guard.js` is the shared classifier
library the shell script loads — it is NOT a standalone hook. Someone added
`git-guard.js` to the hook-runner command in `settings.json` at some point, but
the file was never deployed to `~/.claude/hooks/` (no chezmoi template for it;
the chezmoi seed `create_settings.json` has only `bash-guard.js`). The
functional gap is zero — git-guard.sh covers the same protection — but every
Bash call logs an error.

**Fix**: Remove the non-existent script name from the hook-runner command in
`~/.claude/settings.json`. The chezmoi seed is the source of truth for what
JS hooks should be wired; diff it against the live file to catch future drift.

**Detection**: `[[ -e ~/.claude/hooks/<name>.js ]]` per argument in the
hook-runner commands. A missing file with a fail-open runner is invisible to
normal operation but pollutes stderr in verbose mode.

## Known drift pattern: straggler scripts in `claude/hooks/`

**Symptom**: Unexpected non-JS files appear in `~/.claude/hooks/` (e.g.
`session-start-cheese-flair.sh`) or as untracked files in `claude/hooks/` in
the dotfiles repo.

**Why it happens**: `~/.claude/hooks/` is a **symlink** → `$DOTFILES_DIR/claude/hooks/`.
The JS guard hooks (`bash-guard.js`, `hook-runner.js`, etc.) live there and are
intentional. Before the plugin-tree migration, shell hook scripts (like the
cheese-flair SessionStart hook) were also deployed into `~/.claude/hooks/` and
wired via `settings.json`. When the migration moved them into the plugin tree
(`~/.claude/plugins/local/global/hooks/`, wired via `plugin.json`), the source
files in `claude/hooks/` were deleted — but not always completely. Any straggler
left in `claude/hooks/` is immediately live at `~/.claude/hooks/` via the symlink.

The `.gitignore` explicitly handles known stragglers:

- `claude/lib/cheese-flair.sh` — cheese-flair lib, now deployed by `ap` to the plugin tree
- `claude/reference/cheese-flair.md` — cheese-flair bank, same

**Detection**: Any `.sh` file in `claude/hooks/` is unexpected (only `.js`, `package.json`,
`package-lock.json` are intentional). The broken OLD version is also functionally
incorrect: it used `readlink -f` to resolve the script path, which follows the
`~/.claude/hooks/ → claude/hooks/` symlink into the dotfiles clone where
`lib/cheese-flair.sh` does NOT exist (it's deployed to the plugin tree, not
symlinked). The canonical `agents/hooks/session-start-cheese-flair.sh` was
updated to avoid `readlink -f` for exactly this reason.

**Fix**: Delete the straggler. The plugin-tree copy at
`~/.claude/plugins/local/global/hooks/session-start-cheese-flair.sh` (deployed
by `ap`) is the live hook. Add the filename to `.gitignore` if it keeps
reappearing on migration-in-progress hosts.

## Known drift pattern: `~/.agent-profile/manifest.json` appears untracked in the repo

**Symptom**: `git status` in the dotfiles repo shows `?? agent-profile/manifest.json`.

**Why it happens**: `~/.agent-profile` is a **symlink** → `$DOTFILES_DIR/agent-profile/`.
The `ap install` manifest correctly lives at `~/.agent-profile/manifest.json`
(per `manifest.py:manifest_path`), but because of the symlink that path is
physically `$DOTFILES_DIR/agent-profile/manifest.json`. The `agent-profile/.gitignore`
originally did not exclude it, so it showed up as an untracked file after the
first `ap install global` run.

**Fix**: Add `manifest.json` to `agent-profile/.gitignore`. This was added in
2026-06-11. If the file reappears as untracked, verify the `.gitignore` entry
is present.

## Historical drift pattern: staged `global` installs mutated live Claude user MCP config

**Symptom**: `ap install global --target /tmp/...` once looked like a safe throwaway render, but still invoked `claude mcp remove/add --scope user` and rewrote `~/.claude.json` when `global` carried `mcp_scope: user`.[^staged-global-mcp]

**Old fix**: explicit-target installs were staged as plugin-scope so harness-doctor could render safely. **Current fix**: Claude user-scope MCP registration is disconnected entirely; `_write_mcp_json` returns for `mcp_scope: user` and `user_mcp_registrations()` returns `[]`, so `ap` compiled manifests no longer request `claude mcp add` for global installs.[^claude-user-scope-disconnected]

**Detection**: Any live `~/.claude.json` MCP registration now belongs to Claude/manual/chezmoi ownership, not a fresh `ap install global` side effect.

[^staged-global-mcp]: harness-doctor run on 2026-06-24; `ap install global --target /tmp/harness-doctor-global.nH8lCY` modified `/home/paul/.claude.json` for tilth, context7, tavily, serena, and hallouminate.
[^claude-user-scope-disconnected]: agent-profile/agent_profile/renderers/claude.py:516-540; agent-profile/tests/test_renderer_claude.py:test_user_scope_render_does_not_register_via_cli; agent-profile/tests/test_compile_command.py:test_compile_user_scope_stays_disconnected_from_live_config

## Gotcha: index drift is its own drift class

The hallouminate wiki index (LanceDB) is derived from the markdown on disk. If
`ground` errors with `missing column chunk_id` (or similar), the index is stale
vs the schema — run `hallouminate index` to rebuild. A doctor run should treat
a non-rebuildable index as a dotfiles bug, not just retry.

See [[agent-profile]] for the `ap` render/install model and [[../harnesses/claude]]
for where each Claude config surface lives.
