---
name: harness-doctor
model: sonnet
effort: medium
description: >
  Diagnose and self-heal harness-config drift between Claude, Codex, Cursor,
  Copilot, and the dotfiles registries; also prune bloated
  .claude/settings.local.json permission lists. Use when the user says
  "harness doctor", "check my harness config", "settings drifted", "why is
  this hook firing twice", or asks to audit agent config — or for the settings
  mode: "clean settings", "prune settings", "settings cleanup", or invokes
  /settings-clean; also proactively when settings.local.json exceeds ~30
  entries. In Codex, invoke via `$harness-doctor` or `/skills`, not
  `/harness-doctor`. Do NOT use for general code review (/age) or app-level
  debugging.
---

# harness-doctor

Two modes:

- **Drift audit** (default) — audit the gap between live harness config and
  the dotfiles target state, classify each difference, heal what's safely
  healable. This file.
- **Settings prune** — single-file cleanup of a bloated
  `.claude/settings.local.json` (junk/covered/one-off permission entries,
  missing `Skill(...)` allows). Triggered by "clean settings", "prune
  settings", `/settings-clean`, or a local file past ~30 entries. Read
  `references/settings-prune.md` and follow it; the rest of this file does
  not apply.

## Drift audit

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

All command detail, checklists, and target-state facts live in
`references/drift-audit.md` — read it before step 2.

### 1. Ground — learn the intended state

Read before judging. The repo's design rationale lives in the wiki; the
*direction of travel* lives in git history (commands in the reference).

- **Wiki** (`repo:dotfiles:wiki`): `list_tree`, then `read_markdown` /
  `ground` on `architecture/config-drift.md` **first** (its "Current state"
  section defines who owns each live surface *today* and catalogs known drift
  patterns), then `architecture/agent-profile.md`, `architecture/agents-dir.md`,
  and the relevant `harnesses/<harness>.md`.
- **The wiki overrides this skill.** Any target-state fact baked into this
  skill or its references (paths, ownership, anchor commits) can go stale;
  when the wiki's current-state pages disagree, follow the wiki and flag the
  skill for a `/skill-improver` pass — do not classify drift against the
  stale model.

### 2. Snapshot live config

Read the live files per harness (table in the reference). Use
`cheez-read`/`jq`, not blind `cat`.

### 3. Render the target — diff live vs `ap`

For **Claude**, the authoritative check is feeding live `settings.json`
through the chezmoi modify script and diffing (byte-identical = no drift).
For Codex, Cursor, and Copilot, render `base` into a throwaway target and
diff — never touch live config. Exact commands in the reference.

For each difference, ask: *is the live side a superset (extra entries) or
does it contradict the render?* Extra live-only entries are
remnant-or-local; contradictions are bugs.

### 4. Classify each drift

Walk every difference and bucket it (first match wins):

1. **Stale remnant** — present live, absent from render, AND git history
   shows the repo moved this responsibility elsewhere. Canonical case: a hook
   in `~/.claude/settings.json` whose command duplicates a plugin-managed
   hook (matched by script basename or exact command), or points at a script
   path under `~/.claude/hooks/` that no longer exists. Verify the path:
   `[[ -e <path> ]]` — a dead path is unambiguously stale.
2. **Dotfiles bug** — the repo source is itself wrong. Run the
   dotfiles-bug checklist in the reference.
3. **Expected local** — live-only, no repo provenance, plausibly user-added
   (personal hook, extra permission). Report, never touch.

When unsure between bug and local, **ask the user** (AskUserQuestion) rather
than guess — opening a spurious issue or healing a wanted local entry both
cost trust.

### 5. Heal stale remnants

Legacy hooks and dropped MCPs self-heal **inside the renderers** on every
`ap install` — never hand-roll a jq/toml rewrite of a user-owned file when a
renderer (or a `dots sync`) does it deterministically. The doctor's value is
*explaining why* drift appeared and catching the classes the renderers don't
auto-heal; for those, propose the precise edit and confirm before applying.

One known exception (chezmoi settings gate halting on removed hook keys)
requires a manual live prune — mechanics and the exact renderer functions are
in the reference.

### 6. File dotfiles bugs as gh issues (deduped)

For each confirmed **dotfiles bug**, open a GitHub issue — dedup against open
`harness-doctor`-labeled issues first. Commands, label bootstrap, offline
fallback, and the issue body template are in the reference.

### 7. Learn — write back to the wiki

When the audit surfaces a *new* drift pattern or a non-obvious root cause a
future doctor run would otherwise re-derive, persist it via `add_markdown`
(one topic per file, the *why* not the *what* — follow
`.hallouminate/wiki/index.md` conventions). A recurring drift class extends
`harnesses/<harness>.md` § drift or `architecture/config-drift.md`; don't
duplicate `AGENTS.md` or the code, link related pages with `[[name]]`.

Also check for misplaced project knowledge in wiki repos (agent-memory files
that belong in the wiki) — detection rules in the reference.

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

Lead with what changed and what needs the user's attention. Keep file dumps
out of the report — cite `file:line`, don't paste.

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
