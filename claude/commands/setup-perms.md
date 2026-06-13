---
name: setup-perms
description: Scaffold canonical repo-level permissions for this project — portable rules go to the committed fragment + ap perms render; path-scoped destructive rules go to the gitignored .claude/settings.local.json. Pass --local to keep everything personal.
allowed-tools: Read, Write, Bash, Glob
---

# Setup Project Permissions

Scaffold or update `.agent-profiles/_permissions/profile.yaml` with portable
permissions for this project, render the committed project config via
`ap perms`, then merge machine-specific destructive rules into the gitignored
`.claude/settings.local.json`.

Two layers, split by portability:

- **Committed (portable):** safe, path-free rules — the fragment plus the
  `ap perms` render. Identical on every clone; absolute paths and usernames
  never reach version control.
- **Local (machine-specific):** destructive commands scoped to this clone's
  absolute project root — written only to `.claude/settings.local.json`
  (gitignored).

Pass `--local` to skip the committed render and write both rule sets to the
personal gitignored layer.

## Instructions

### 1. Detect project type

Check for these indicator files in the project root:

| Indicator | Project Type |
|-----------|-------------|
| `package.json` | node |
| `pyproject.toml` or `setup.py` | python |
| `Cargo.toml` | rust |
| `go.mod` | go |
| `Gemfile` | ruby |
| `.brew` or `zshrc` or `zsh/` dir | dotfiles |

A project can match multiple types (polyglot). If none match, use base permissions only.

### 2. Build the two rule sets

**Committed, portable set** — safe (read-only / non-destructive) commands,
unscoped. Combine the base layer with each detected type's layer. This set is
committed (fragment + rendered `settings.json` + `.codex/`), so it MUST stay
path-free: never include an absolute path, a `$PWD` substitution, or anything
machine-specific.

**Base (always included):**

```
Bash(git:*)
Bash(ls:*)
Bash(cat:*)
Bash(head:*)
Bash(tail:*)
Bash(wc:*)
Bash(which:*)
Bash(echo:*)
Bash(grep:*)
Bash(find:*)
Bash(diff:*)
Bash(sort:*)
Bash(tr:*)
Bash(test:*)
Bash([:*)
Bash(true)
Bash(false)
Bash(gh:*)

# MCP & web
WebSearch
```

**Dotfiles/shell layer:**

```
Bash(bash:*)
Bash(sh:*)
Bash(zsh:*)
Bash(source:*)
Bash(shellcheck:*)
Bash(brew:*)
Bash(yq:*)
Bash(jq:*)
Bash(bats:*)
Bash(tinty:*)
Bash(home-manager:*)
Bash(nix:*)
Bash(plutil:*)
Bash(claude:*)
Bash(python3:*)
Bash(alias:*)
```

**Node/TS layer:**

```
Bash(npm:*)
Bash(npx:*)
Bash(node:*)
Bash(pnpm:*)
Bash(yarn:*)
Bash(tsc:*)
Bash(eslint:*)
Bash(prettier:*)
Bash(jest:*)
Bash(vitest:*)
```

**Python layer:**

```
Bash(uv:*)
Bash(python:*)
Bash(python3:*)
Bash(pytest:*)
Bash(mypy:*)
Bash(ruff:*)
```

**Rust layer:**

```
Bash(cargo:*)
Bash(rustc:*)
Bash(rustup:*)
```

**Go layer:**

```
Bash(go:*)
Bash(gopls:*)
```

**Ruby layer:**

```
Bash(bundle:*)
Bash(ruby:*)
Bash(gem:*)
Bash(rake:*)
```

**Local destructive set** — write/move/delete commands scoped to the project
root so they only run inside this clone. These embed the absolute path, so
they are machine-specific by construction and go ONLY to the gitignored
`.claude/settings.local.json` — never the fragment, never the committed
`settings.json`:

```
Bash(mkdir <abs-project-root>/*)
Bash(mv <abs-project-root>/*)
Bash(cp <abs-project-root>/*)
Bash(chmod <abs-project-root>/*)
Bash(sed <abs-project-root>/*)
Bash(awk <abs-project-root>/*)
Bash(xargs <abs-project-root>/*)
```

Replace `<abs-project-root>` with the real absolute path of the current
working directory (e.g. `/Users/you/Dev/myproject`). The substitution is safe
here precisely because the target file is gitignored.

### 3. Write the committed fragment

Write `.agent-profiles/_permissions/profile.yaml` with ONLY the portable set,
using the canonical grammar. Create the directory if it does not exist.
Overwrite the entire `permissions` block on re-run — do NOT merge with old
accumulated permissions. Sort the allow list alphabetically. Example:

```yaml
name: _permissions
settings:
  permissions_allow:
    - Bash([:*)
    - Bash(cat:*)
    - Bash(diff:*)
    - Bash(echo:*)
    - Bash(false)
    - Bash(find:*)
    - Bash(gh:*)
    - Bash(git:*)
    - Bash(grep:*)
    - Bash(head:*)
    - Bash(ls:*)
    - Bash(sort:*)
    - Bash(tail:*)
    - Bash(test:*)
    - Bash(tr:*)
    - Bash(true)
    - Bash(wc:*)
    - Bash(which:*)
    - WebSearch
  permissions_deny: []
```

No absolute paths, no `$PWD` — if a rule needs the project path, it belongs in
the local destructive set (step 5), not here.

### 4. Render with ap perms

- Default (committed files): `ap perms --target "$(pwd)"`
- Under `--local` (personal, gitignored): `ap perms --local --target "$(pwd)"`

This writes:

- **Claude** → `.claude/settings.json` (or `settings.local.json` under `--local`)
- **Codex** → `.codex/rules/ap-canonical.rules` + `.codex/config.toml`
  tool scopes (skipped under `--local`)

### 5. Merge the local destructive set into settings.local.json

Read `.claude/settings.local.json` if it exists (create it otherwise) and
union the destructive rules into `permissions.allow`: keep every existing
entry, dedupe, sort alphabetically, and preserve all sibling keys. Never
remove entries you did not add.

Ordering under `--local`: run `ap perms --local` (step 4) FIRST, then this
merge — `ap perms` owns `permissions.{allow,deny}` wholesale and would drop
rules merged before it ran.

### 6. Print a summary

```
Detected: dotfiles, python
Committed (portable): 38 rules → .agent-profiles/_permissions/profile.yaml,
  .claude/settings.json, .codex/rules/ap-canonical.rules
Local (destructive): 7 rules → .claude/settings.local.json
```

## Codex trust note

Codex project config loads only for **trusted** projects. If Codex does not
pick up the project overlay, the user must trust the repo interactively via
the Codex TUI or CLI. This is expected behavior — not a bug in the overlay.

## Important

- The committed fragment and `settings.json` must never contain absolute
  paths or `$PWD` substitutions — portability across clones and machines is
  the contract. Path-scoped rules live only in `settings.local.json`.
- Codex gets no destructive path rules: it has no personal-layer analog
  (`ap perms --local` skips it), so Codex prompts for destructive commands.
  Expected, not a gap to fix here.
- Overwrite the entire `permissions` block in `profile.yaml` on re-run — do
  NOT merge with old accumulated permissions. For `settings.local.json` the
  opposite holds: merge additively, never drop entries you did not write.
- A bare `ap perms --local` re-render overwrites `permissions.{allow,deny}`
  in `settings.local.json` with just the portable set, dropping the merged
  destructive rules — re-run `/setup-perms --local` to restore them.
- Sort allow lists alphabetically for readability.
- The `deny` array should always be empty unless explicitly requested (hooks
  handle blocking).
- The `profile.yaml` fragment is committed to the repo; `settings.local.json`
  is gitignored.
