---
name: setup-perms
description: Scaffold canonical repo-level permissions for this project (committed .claude/settings.json + .codex/ via ap perms). Pass --local for the gitignored personal layer.
allowed-tools: Read, Write, Bash, Glob
---

# Setup Project Permissions

Scaffold or update `.agent-profiles/_permissions/profile.yaml` with sensible
permissions for this project, then render the committed project config via
`ap perms`.

Pass `--local` to write the personal gitignored layer
(`.claude/settings.local.json`) instead of the committed files.

## Instructions

1. **Detect project type** by checking for these indicator files in the project root:

| Indicator | Project Type |
|-----------|-------------|
| `package.json` | node |
| `pyproject.toml` or `setup.py` | python |
| `Cargo.toml` | rust |
| `go.mod` | go |
| `Gemfile` | ruby |
| `.brew` or `zshrc` or `zsh/` dir | dotfiles |

A project can match multiple types (polyglot). If none match, use base permissions only.

1. **Determine the project root** using the current working directory. This path is
   used to scope destructive commands. Refer to it as `$PWD` below.

   **IMPORTANT:** Replace `$PWD` with the actual absolute path in the output
   (e.g. `/Users/paulsorensen/Dev/myproject`). Do NOT leave `$PWD` as a literal string.

2. **Build the allow/deny lists** by combining layers. Start with the base layer,
   then add each detected type's layer.

Commands are split into two categories:

- **Safe (read-only / non-destructive):** unscoped, can run anywhere
- **Destructive (writes / moves / deletes):** scoped to `$PWD/*` so they only work inside the project

**Base (always included):**

```
# Safe — unscoped
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

# Destructive — scoped to project
Bash(mkdir $PWD/*)
Bash(mv $PWD/*)
Bash(cp $PWD/*)
Bash(chmod $PWD/*)
Bash(sed $PWD/*)
Bash(awk $PWD/*)
Bash(xargs $PWD/*)

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

1. **Write `.agent-profiles/_permissions/profile.yaml`** with the computed
   allow/deny set using the canonical grammar. Create the directory if it does not
   exist. Overwrite the entire `permissions` block on re-run — do NOT merge with
   old accumulated permissions. Example:

```yaml
name: _permissions
settings:
  permissions_allow:
    - Bash([:*)
    - Bash(awk $PWD/*)
    - Bash(cat:*)
    - Bash(chmod $PWD/*)
    - Bash(cp $PWD/*)
    - Bash(diff:*)
    - Bash(echo:*)
    - Bash(false)
    - Bash(find:*)
    - Bash(gh:*)
    - Bash(git:*)
    - Bash(grep:*)
    - Bash(head:*)
    - Bash(ls:*)
    - Bash(mkdir $PWD/*)
    - Bash(mv $PWD/*)
    - Bash(sed $PWD/*)
    - Bash(sort:*)
    - Bash(tail:*)
    - Bash(test:*)
    - Bash(tr:*)
    - Bash(true)
    - Bash(wc:*)
    - Bash(which:*)
    - Bash(xargs $PWD/*)
    - WebSearch
  permissions_deny: []
```

   Replace `$PWD` with the actual absolute path. Sort the allow list alphabetically.

1. **Run `ap perms`** to render the canonical project config:

   - Default (committed files): `ap perms --target $PWD`
   - With `--local` passthrough (personal, gitignored): `ap perms --local --target $PWD`

   This writes:
   - **Claude** → `$PWD/.claude/settings.json` (or `settings.local.json` under `--local`)
   - **Codex** → `$PWD/.codex/rules/ap-canonical.rules` + `$PWD/.codex/config.toml`
     tool scopes (skipped under `--local`)

2. **Print a summary** like:

```
Detected: dotfiles, python
Permissions: 45 rules (base: 27, dotfiles: 16, python: 6)
Wrote: .agent-profiles/_permissions/profile.yaml
Rendered: .claude/settings.json, .codex/rules/ap-canonical.rules
```

## Codex trust note

Codex project config loads only for **trusted** projects. If Codex does not
pick up the project overlay, the user must trust the repo interactively via
the Codex TUI or CLI. This is expected behavior — not a bug in the overlay.

## Important

- Overwrite the entire `permissions` block in `profile.yaml` on re-run — do NOT merge with old accumulated permissions
- Sort the allow list alphabetically for readability
- The `deny` array should always be empty unless explicitly requested (hooks handle blocking)
- Under `--local`, the committed `settings.json` is NOT written; only `settings.local.json`
- The `profile.yaml` fragment is committed to the repo; `settings.local.json` is gitignored
