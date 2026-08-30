# Drift audit — mechanics reference

Command detail and checklists backing the drift-audit protocol in `SKILL.md`.
The wiki (`repo:dotfiles:wiki`) overrides any target-state fact here that goes
stale.

## Target-state facts

- Registries (edit surface): `agents/mcp/registry.yaml`,
  `agents/hooks/registry.yaml`, `agents/registry.yaml`, `skills/`.
- `base` = registry union (render primitive). `profiles/global` is a
  **deprecated stub** superseded by `profiles/live` — check the profile's own
  yaml before describing it.
- Claude's `~/.claude/settings.json` (hooks, enabledPlugins,
  extraKnownMarketplaces, permissions) is **chezmoi-authoritative**: composed
  wholesale by `chezmoi/dot_claude/modify_settings.json` from
  `chezmoi/.chezmoidata/claude.yaml` + the plugin registries. Skills and
  agents render flat to `~/.claude/skills/` and `~/.claude/agents/`; a
  `~/.claude/plugins/local/` tree is historical and may be absent entirely.
- The Claude-specific JS guards (`~/.claude/hooks/*.js`), `rtk`, and any tmux
  hook are **settings-only and legit** — not plugin-managed, so not drift.
- Historical anchor commit: **#217 `feat(ap): add global profile + migrate
  settings.json to chezmoi seed`** — the point hooks first moved out of
  `settings.json`. Since then Claude went fully chezmoi-authoritative.
  Anything live matching a pre-#217 shape is still a stale-remnant candidate,
  but the *current* owner is the modify script, not a plugin tree (which may
  not exist at all on the machine).

## Grounding commands

Git history — the migration arc that distinguishes stale from novel:

```bash
git -C "$DOTFILES_DIR" log --oneline -20 -- agents/ profiles/ chezmoi/dot_claude/
git -C "$DOTFILES_DIR" log --oneline --grep='ap\|migrat\|settings\|hook' -20
```

If `ground` errors with a schema/index error (e.g. `missing column chunk_id`),
the LanceDB index is stale — run `hallouminate index` (or note it as a
dotfiles bug if it won't rebuild) and fall back to `read_markdown`.

## Live config snapshot

Read the live files per harness (use `cheez-read`/`jq`, not blind `cat`):

| Harness | Live files |
|---|---|
| claude | `~/.claude/settings.json` (+ `~/.claude/plugins/local/global/` only if that historical tree exists) |
| codex | `~/.codex/config.toml` (`[mcp_servers]`, `[[hooks.*]]`), `~/.codex/hooks.json` |
| cursor | `~/.cursor/mcp.json`, `~/.cursor/hooks.json` |
| copilot | `~/.copilot/mcp-config.json`, `~/.copilot/hooks/` |

## Render + diff commands

For **Claude**, the authoritative check is the chezmoi modify script itself —
feed it the live file and diff the result against live (byte-identical = no
drift):

```bash
sh "$DOTFILES_DIR/chezmoi/dot_claude/modify_settings.json" \
  < ~/.claude/settings.json | diff - ~/.claude/settings.json
```

For Codex, Cursor, and Copilot, render `base` into a throwaway target (never
touch live config) and diff:

```bash
TMP="$(mktemp -d)"
DOTFILES_DIR="$DOTFILES_DIR" ap install base --target "$TMP"
dots profile describe live            # resolved manifest for the live overlay
# Compare Codex MCP tables and Cursor/Copilot MCP files with rendered payloads.
```

## Dotfiles-bug checklist

Repo-source-is-wrong checks (any hit is a **dotfiles bug**):

- A `script:` in `agents/hooks/registry.yaml` whose file is missing.
- A hook `event:` not in `HOOK_EVENTS_VALID` (`agents/hooks/lib.sh`).
- A Codex user-level `~/.codex/hooks.json` command that starts with
  `bash .codex/hooks/` or otherwise names a relative hook script path.
  User-level Codex hooks run from the session cwd, so repo-relative commands
  are unsafe drift.
- Duplicate Codex hook wiring: the same managed hook basename appears in both
  `~/.codex/hooks.json` and legacy `[[hooks.<event>]]` blocks in
  `~/.codex/config.toml`.
- An MCP referencing an unset `${VAR}` but not marked `optional: true`.
- A skill dir without a `SKILL.md`, or a registry `body_path` that 404s.
- The wiki index failing to rebuild (`hallouminate index` errors).
- A `run_onchange` hash input list omitting a file the script reads.

## Heal mechanics

Two stale-remnant classes self-heal **inside the renderers**, on every
`ap install` — not via a bolt-on script:

- **Legacy hooks.** Each renderer prunes its own harness's pre-ap hook
  leftovers:
  - **claude** — `claude.py:_clean_legacy_settings_hooks` strips
    `settings.json` hooks that duplicate a plugin-managed hook (by script
    basename or exact command), keyed off the hooks it just wired into
    `plugin.json`.
  - **codex** — `codex.py:_clean_legacy_config_toml_hooks` strips legacy
    `[[hooks.*]]` blocks from `config.toml` the same way.
- **Dropped MCPs.** `cli.py:_reconcile_dropped_mcps` reports registry entries
  removed since the prior resolved manifest. Non-isolated live MCP config is
  chezmoi/user-owned, so diagnose and repair it through its authoritative
  owner; do not expect `ap install` to mutate those files.

**Known exception — chezmoi settings gate halts on removed hook keys.** Since
claude went chezmoi-authoritative, `chezmoi/dot_claude/modify_settings.json`
halts `dots sync` on any live `settings.json` key-path absent from the desired
document. When a commit *removes* a hook event key (or the last hook carrying a
field like `timeout`) from `chezmoi/.chezmoidata/claude.yaml`, the stranded
live key-path trips that gate and no renderer or sync can clear it — this is
the one case where a manual live prune IS the heal:

```bash
jq 'del(.hooks.<RemovedEvent>)' ~/.claude/settings.json > /tmp/s.json \
  && jq -e 'type=="object"' /tmp/s.json >/dev/null \
  && mv /tmp/s.json ~/.claude/settings.json
dots sync   # wholesale write owns hooks from here
```

Confirm each pruned key-path against the removing commit first
(`git log -p -- chezmoi/.chezmoidata/claude.yaml`) — a live-only key with *no*
removal commit is app-introduced and must be folded in, not pruned. Details:
`.hallouminate/wiki/architecture/config-drift.md` § registry hook-event
removal.

## gh issue mechanics

Dedup first:

```bash
gh issue list --repo "$REPO" --state open --label harness-doctor --json number,title
```

Skip any bug whose title substantially matches an open issue. For novel bugs:

```bash
gh issue create --repo "$REPO" \
  --title "harness-doctor: <one-line bug>" \
  --label harness-doctor \
  --body "$(cat <<'EOF'
**Found by** /harness-doctor on <date>.

**Symptom**: <what's wrong, with file:line>
**Root cause**: <why — cite git history / wiki>
**Target state**: <what ap/registries should produce>
**Suggested fix**: <concrete edit>
EOF
)"
```

Create the `harness-doctor` label first if absent (`gh label create
harness-doctor --color BFD4F2 --description "Drift/bug found by /harness-doctor"`).
If `gh` is unauthenticated or offline, write the issue bodies to
`.cheese/harness-doctor/issues-<date>.md` and tell the user to file them.

## Misplaced project knowledge (wiki repos only)

Auto-memory is disabled globally (`autoMemoryEnabled: false`, issue #717), so
a repo with a `.hallouminate/wiki/` should hold no project-scoped agent
memory. When `.hallouminate/wiki/` exists, scan
`~/.claude/projects/<slug>/memory/` for files whose frontmatter declares
`type: project` and list each under **Needs your call**, recommending
migration into the wiki (`/wiki-curator` / `add_markdown`). Do **not** open a
gh issue (the content is not a repo-source bug) and do **not** auto-delete
(that would destroy the only copy before it is migrated).
