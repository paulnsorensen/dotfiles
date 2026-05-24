---
name: cursor
model: haiku
context: fork
description: Explain and manage how Cursor configuration is fed in this repo — the "/chezmoi for Cursor". Use when the user says "manage cursor config", asks about `~/.cursor`, "cursor skills", "cursor plugin", "cursor deploy", "where do cursor skills come from", mentions `ap` / agent-profile in a Cursor context, or hits a stray-artifact / collision / clobber problem under `~/.cursor`. Covers the three config channels, the machine-vs-project split, the ownership manifest, the four hard rules, and inspect/debug. Do NOT use for Claude/Codex/opencode harness config (that is the MCP/hook/skill registries) or for the PR #181 `ap` renderer's own internals.
allowed-tools: Read, Grep, Glob, Bash(jq:*), Bash(git:*), Bash(ls:*), Bash(cat:*)
---

# Cursor config management

Cursor configuration in this repo is fed by **three independent channels**.
This skill is the single mental model for them — what owns what, where it
lands, and the rules that keep them from trampling each other.

## The three channels

| # | Channel | Scope | Source → Target | Ownership |
|---|---------|-------|-----------------|-----------|
| 1 | **cheese-grok plugin** | machine | `cursor/plugins/local/cheese-grok/` → `~/.cursor/{skills,rules,commands,hooks}` + merged `~/.cursor/{hooks.json,modes.json}` | dotfiles manifest (below) |
| 2 | **external skills** | machine | `gh skill install … --agent cursor --scope user` for every `skills/_registry.yaml` entry | `gh` tracks its own dirs |
| 3 | **`ap` agent-profile renderer** (PR #181) | project | renders a *target repo's* agents/commands/skills into `<repo>/.cursor/`; skills go to cross-harness `.agents/skills/` | `ap`'s own project-scoped manifest |

Channel 1 is driven by `chezmoi/lib/install-cursor-plugin.sh`. Channel 2 is
driven by `chezmoi/lib/install-external.sh` (because `.env` `SKILL_HARNESSES`
includes `cursor`). Both write **machine-level** `~/.cursor`. Channel 3 is
**project-level** and writes `<repo>/.cursor` — it is a different layer.

## Machine vs project

- **Machine (`~/.cursor`)** = channel 1 (cheese-grok) + channel 2 (`gh`
  externals). cheese-grok's items are tracked by the dotfiles manifest;
  `gh`'s items are tracked by `gh`. They coexist only because their
  skill names are **disjoint** — the collision guard enforces this.
- **Project (`<repo>/.cursor` via `ap`)** = channel 3. Skills route to the
  cross-harness `.agents/skills/`, not `.cursor/skills/`. `ap` emits no
  `rules/` or `modes/`. This layer never touches `~/.cursor`.

There is **no bridge** between the machine plugin and the `ap` overlay — see
[Relationship to PR #181](#relationship-to-pr-181).

## Ownership manifest

cheese-grok's whole-file/dir artifacts are tracked in ONE machine-level,
ref-counted manifest:

```
~/.cursor/.dotfiles-cursor-manifest.json
  = { "<plugin>": { "files": ["skills/design-doc", "commands/tighten.md",
                              "rules/reader-companion.mdc",
                              "hooks/block-destructive.sh"] } }
```

This **replaces** the old per-dir `.dotfiles-managed-<plugin>` markers.
Semantics (mirroring the `ap` manifest pattern):

- **validate-on-read** — a corrupt manifest fails the deploy loud; a silent
  no-op on cleanup would be a correctness bug.
- **ref-counted** — a path dropped from a plugin's source is removed only
  when no *other* plugin still claims it.
- **diff-and-clean** — `dropped = old.files − newly-deployed`; each dropped
  path is `rm -rf`'d (subject to ref-count) on the next run.

`hooks.json` / `modes.json` entries are tracked differently — by a
`"_plugin": "<name>"` tag on each merged entry, not in the manifest, because
they are merged JSON rather than whole-file artifacts.

## Hard rules

1. **Never run `ap install` inside the dotfiles repo.** It writes
   `dotfiles/.cursor/` and recreates the stray-artifact mess. `ap` is for
   *target* repos.
2. **Cursor deploy outputs are gitignored.** Only `cursor/plugins/local/`
   is tracked source. `cursor/{commands,hooks,rules,skills,hooks.json,
   mcp.json,modes.json}` are ignored.
3. **`install-cursor-plugin.sh` refuses an in-repo target.** It dies loud if
   `cursor_home` is at or inside the dotfiles repo root, writing nothing.
4. **cheese-grok and `gh` hold disjoint `~/.cursor/skills` names.** A deploy
   that would land on a name owned by `gh` or a hand-authored item warns and
   skips, never clobbers.

## Workflow

| Step | Command |
|------|---------|
| Edit plugin source | `cursor-plugin-edit` (opens `cursor/plugins/local/`) |
| Apply | `cursor-plugin-sync` (or `dots sync`) |
| Inspect deployed | `cursor-plugin-ls` |

After a sync, restart Cursor for skills/rules/modes changes to take effect.

## Inspect / debug

```bash
# Where the manifest lives and what each plugin claims:
jq . ~/.cursor/.dotfiles-cursor-manifest.json

# Who owns a given skill name? (empty under .dotfiles-* ⇒ gh/user-owned)
jq -r 'to_entries[] | select(.value.files|index("skills/<name>")) | .key' \
   ~/.cursor/.dotfiles-cursor-manifest.json

# Deploy into a scratch ~/.cursor instead of the real one:
CURSOR_HOME=/tmp/cursor-scratch \
  chezmoi/lib/install-cursor-plugin.sh cursor/plugins/local/cheese-grok
```

- `CURSOR_HOME` (or a second positional arg) overrides the target; defaults
  to `~/.cursor`.
- A `WARN: skipping skills/<name>: owned by gh/user` line means the collision
  guard found a foreign same-named item — resolve the name clash, don't
  force it.
- A `refusing to deploy into the dotfiles repo` die means `CURSOR_HOME`
  pointed inside the repo — point it at `~/.cursor`.

## Relationship to PR #181

PR #181's `ap` renderer is a **project overlay**: it writes `<repo>/.cursor`,
routes skills to `.agents/skills/`, and emits no rules/modes — it cannot
express the cheese-grok machine deploy. The two layers stay separate by
design. Both adopt the same *manifest pattern* (ref-counted, validate-on-read,
diff-and-clean) but keep separate files: this one is machine-scoped and keyed
by **plugin**; `ap`'s is project-scoped and keyed by **profile**. No shared
file, no timing coupling.
