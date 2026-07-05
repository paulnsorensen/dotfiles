---
name: harness-doctor
model: sonnet
effort: medium
description: >
  Diagnose and self-heal harness-config drift between live files
  (~/.claude, ~/.codex, opencode, Cursor, Copilot) and what `ap` renders from
  the dotfiles registries. Use when the user says "harness doctor", "check my
  harness config", "settings drifted", "why is this hook firing twice", or asks
  to audit agent config. In Codex, invoke via `$harness-doctor` or `/skills`,
  not `/harness-doctor`. Do NOT use for general code review (/age), single-file
  permission cleanup (/settings-clean), or app-level debugging.
---

# harness-doctor

Audit the gap between **live** harness config on this machine and the
**target state** the dotfiles repo intends (`ap` rendering the registries into
each harness). Drift accumulates because some live files are seed-once and
user-owned — chezmoi never prunes them — so pre-migration leftovers linger
(dead hooks, double-fired hooks, stale MCP entries).

The doctor's job is to **tell three kinds of drift apart** and act
differently on each:

| Class | What it is | Action |
|---|---|---|
| **Stale remnant** | Live config matching a pattern git history shows the repo migrated *away* from (e.g. registry hooks left in `settings.json` after they moved into the plugin tree). | **Self-heal** — prune it. |
| **Dotfiles bug** | The repo's own source of truth is wrong/inconsistent (registry points at a missing script, invalid hook event, required MCP var not marked `optional`, wiki index won't rebuild). | **Open a gh issue** (deduped). |
| **Expected local** | Machine-local user additions not sourced from the repo (a personal hook, an extra permission, a one-off MCP). | **Leave alone** — report only. |

The hard part is the classification, not the diffing. A raw diff between live
and rendered is noisy; git history + the wiki are what let you say "this is a
leftover we abandoned" vs "this is a bug" vs "this is the user's own".

## Protocol

### 1. Ground — learn the intended state

Read before judging. The repo's design rationale lives in the wiki; the
*direction of travel* lives in git history.

- **Wiki** (`repo:dotfiles:wiki`): `list_tree`, then `read_markdown` /
  `ground` on `architecture/agent-profile.md`, `architecture/agents-dir.md`,
  and the relevant `harnesses/<harness>.md`. These define what `ap` is
  *supposed* to produce and where each harness's config lives.
  - If `ground` errors with a schema/index error (e.g. `missing column
    chunk_id`), the LanceDB index is stale — run `hallouminate index` (or note
    it as a dotfiles bug if it won't rebuild) and fall back to `read_markdown`.
- **Git history** — the migration arc that distinguishes stale from novel:

  ```
  git -C "$DOTFILES_DIR" log --oneline -20 -- agents/ profiles/ chezmoi/dot_claude/
  git -C "$DOTFILES_DIR" log --oneline --grep='ap\|migrat\|settings\|hook' -20
  ```

  Anchor commit: **#217 `feat(ap): add global profile + migrate settings.json
  to chezmoi seed`** — the point hooks moved from `settings.json` into the
  plugin tree and `settings.json` became a seed-once `create_` file. Anything
  in `settings.json` matching a *pre-#217* shape is a stale-remnant candidate.

Key target-state facts to hold:

- Registries (edit surface): `agents/mcp/registry.yaml`,
  `agents/hooks/registry.yaml`, `agents/registry.yaml`, `skills/`.
- `base` = registry union (render primitive); `global` = live install overlay
  (`target_default: $HOME`, `local` marketplace, `enabled_plugins: global@local`).
- Hook wiring lives in the **plugin tree's** `plugin.json`
  (`~/.claude/plugins/local/global/.claude-plugin/plugin.json`), **NOT** in
  `~/.claude/settings.json`. `ap install global` only jq-merges
  `enabledPlugins` + `extraKnownMarketplaces` into `settings.json`, preserving
  user keys — it never writes `.hooks` there.
- The Claude-specific JS guards (`~/.claude/hooks/*.js`), `rtk`, and any tmux
  hook are **settings-only and legit** — not plugin-managed, so not drift.

### 2. Snapshot live config

Read the live files per harness (use `cheez-read`/`jq`, not blind cat):

| Harness | Live files |
|---|---|
| claude | `~/.claude/settings.json`, `~/.claude/plugins/local/global/.claude-plugin/plugin.json`, `~/.claude/plugins/local/global/.mcp.json` |
| codex | `~/.codex/config.toml` (`[mcp_servers]`, `[[hooks.*]]`), `~/.codex/hooks.json` |
| opencode | `~/.config/opencode/opencode.json` (`mcp`, `provider`) |
| cursor | `~/.cursor/mcp.json`, `~/.cursor/hooks.json` |
| copilot | `~/.copilot/mcp-config.json`, `~/.copilot/hooks/` |

### 3. Render the target — diff live vs `ap`

Render `base` into a throwaway target (never touches live config) and diff:

```bash
TMP="$(mktemp -d)"
DOTFILES_DIR="$DOTFILES_DIR" ap install base --target "$TMP"
dots profile describe global          # resolved manifest for the live overlay
# Compare e.g. rendered plugin.json hooks vs live plugin.json,
# rendered .mcp.json vs live, codex config_servers vs rendered.
```

For each difference, ask: *is the live side a superset (extra entries) or does
it contradict the render?* Extra live-only entries are remnant-or-local;
contradictions are bugs.

### 4. Classify each drift

Walk every difference and bucket it (first match wins):

1. **Stale remnant** — present live, absent from render, AND git history shows
   the repo moved this responsibility elsewhere. Canonical case: a hook in
   `~/.claude/settings.json` whose command duplicates a plugin-managed hook
   (matched by script basename or exact command), or points at a script path
   under `~/.claude/hooks/` that no longer exists. Verify the path:
   `[[ -e <path> ]]` — a dead path is unambiguously stale.
2. **Dotfiles bug** — the repo source is itself wrong. Checks:
   - A `script:` in `agents/hooks/registry.yaml` whose file is missing.
   - A hook `event:` not in `HOOK_EVENTS_VALID` (`agents/hooks/lib.sh`).
   - A Codex user-level `~/.codex/hooks.json` command that starts with `bash .codex/hooks/` or otherwise names a relative hook script path. User-level Codex hooks run from the session cwd, so repo-relative commands are unsafe drift.
   - Duplicate Codex hook wiring: the same managed hook basename appears in both `~/.codex/hooks.json` and legacy `[[hooks.<event>]]` blocks in `~/.codex/config.toml`.
   - An MCP referencing an unset `${VAR}` but not marked `optional: true`.
   - A skill dir without a `SKILL.md`, or a registry `body_path` that 404s.
   - The wiki index failing to rebuild (`hallouminate index` errors).
   - A `run_onchange` hash input list omitting a file the script reads.
3. **Expected local** — live-only, no repo provenance, plausibly user-added
   (personal hook, extra permission). Report, never touch.

When unsure between bug and local, **ask the user** (AskUserQuestion) rather
than guess — opening a spurious issue or healing a wanted local entry both cost
trust.

### 5. Heal stale remnants

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
- **Dropped MCPs.** `cli.py:_reconcile_dropped_mcps` diffs the prior resolved
  manifest (cached in `manifest.json`) against the current one and calls each
  renderer's `prune_mcps` to evict servers removed from the registry that a
  prior render merged into a persistent file (codex `config.toml`,
  opencode/cursor/copilot JSON, claude user-scope `~/.claude.json`). claude
  plugin-scoped `.mcp.json` is whole-file so it never drifts.

So the heal for both is just **`dots profile install global`** (or a full
`dots sync`) — it re-runs the renderers + reconcile. opencode/cursor/copilot
receive no registry hooks, so there's no hook drift there.

The doctor's value is *explaining why* drift appeared and catching the classes
the renderers don't auto-heal. For those, propose the precise edit and confirm
before applying — never hand-roll a jq/toml rewrite of a user-owned file when a
renderer (or a `dots sync`) does it deterministically.

**Known exception — chezmoi settings gate halts on removed hook keys.** Since
claude went chezmoi-authoritative, `chezmoi/dot_claude/modify_settings.json`
halts `dots sync` on any live `settings.json` key-path absent from the desired
document. When a commit *removes* a hook event key (or the last hook carrying a
field like `timeout`) from `chezmoi/.chezmoidata/claude.yaml`, the stranded live
key-path trips that gate and no renderer or sync can clear it — this is the one
case where a manual live prune IS the heal:

```bash
jq 'del(.hooks.<RemovedEvent>)' ~/.claude/settings.json > /tmp/s.json \
  && jq -e 'type=="object"' /tmp/s.json >/dev/null \
  && mv /tmp/s.json ~/.claude/settings.json
dots sync   # wholesale write owns hooks from here
```

Confirm each pruned key-path against the removing commit first (`git log -p --
chezmoi/.chezmoidata/claude.yaml`) — a live-only key with *no* removal commit is
app-introduced and must be folded in, not pruned. Details:
`.hallouminate/wiki/architecture/config-drift.md` § registry hook-event removal.

### 6. File dotfiles bugs as gh issues (deduped)

For each confirmed **dotfiles bug**, open a GitHub issue — but dedup first:

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

### 7. Learn — write back to the wiki

When the audit surfaces a *new* drift pattern or a non-obvious root cause a
future doctor run would otherwise re-derive, persist it via `add_markdown`
(one topic per file, the *why* not the *what* — follow
`.hallouminate/wiki/index.md` conventions). Good homes:

- A recurring drift class → extend `harnesses/<harness>.md` § drift, or a new
  `architecture/config-drift.md`.
- Don't duplicate `AGENTS.md` or the code; link related pages with `[[name]]`.

After writing, the file reindexes automatically; if you edited via a plain file
write instead, run `hallouminate index`.

### 8. Report

Emit a compact summary grouped by class:

```
## harness-doctor — <date>

### Healed (N)
- <harness>: <what was pruned> — <one-line why>

### Filed as issues (N)
- #<num> <title>

### Expected-local (ignored, N)
- <harness>: <entry> — user-added

### Needs your call (N)
- <ambiguous item> — <question>
```

Lead with what changed and what needs the user's attention. Keep file dumps out
of the report — cite `file:line`, don't paste.

## Guard rails

- **Never** rewrite a live config by hand when a tested helper exists.
- **Never** touch `settings.json`'s non-hook keys, the JS guards, `rtk`, or
  inline user hooks — those are not plugin-managed.
- **Never** open an issue without deduping against open issues first.
- **Never** fabricate git history or a wiki claim — cite the commit / page.
- Healing edits a user-owned file in place: the renderers rewrite
  `settings.json` / `config.toml` directly with no backup file. There is no
  `.bak` to report — `git` / `chezmoi` is the undo path. Always report which
  file changed and what was pruned.
