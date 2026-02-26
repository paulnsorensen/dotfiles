---
name: lsp
description: >
  Auto-detect project languages and enable only the relevant LSP plugins locally.
  Use when starting work in a new project, when switching projects, or when the user
  says "set up LSPs", "enable language servers", "/lsp", or mentions wanting code
  intelligence. Also useful proactively when you notice a project has languages that
  aren't covered by currently enabled LSPs. Supports --all, --list, and --disable flags.
permissions:
  allow:
    - "Bash(yq:*)"
    - "Bash(jq:*)"
---

# lsp

Detect project languages. Enable matching LSPs. Write to local settings only.

## When do you need LSPs?

ast-grep, Serena, and LSP plugins serve different roles:

| Capability | ast-grep (`/trace`) | Serena MCP | LSP plugins |
|---|---|---|---|
| Structural pattern search | Yes | No | No |
| Symbol lookup / cross-refs | No | Yes | Yes |
| Go-to-definition (resolved) | No | Yes | Yes |
| Type inference / hover types | No | No | Yes |
| Diagnostics / type errors | No | No | Yes |
| Works without project config | Yes | Needs activation | Needs tsconfig etc. |

**When to enable LSPs:**
- You need type information that Serena alone can't provide
- Working in a typed language (TypeScript, Python with type hints, Go, Rust)
- Interactive session where startup overhead is acceptable

**When to skip LSPs:**
- Headless/CI sessions (startup cost, no interactivity)
- Quick structural searches (use `/trace` instead)
- Symbol navigation only (Serena suffices)

LSP plugins install language servers at startup — expensive for headless/CI sessions.
This skill enables them per-project in `~/.claude/settings.local.json` so only
interactive sessions on machines that opt in get the overhead.

## Registry

The source of truth is `~/Dev/dotfiles/claude/plugins/lsp-registry.yaml`.
Each LSP entry has an `extensions` list mapping file extensions to the plugin name.

## Modes

| Flag | Behavior |
|------|----------|
| *(default)* | Scan project, enable LSPs for detected languages |
| `--all` | Enable every LSP in the registry |
| `--list` | Show what would be enabled (dry run, no writes) |
| `--disable` | Remove all LSP entries from local settings |

## Protocol

### 1. Parse flags

Check the arguments for `--all`, `--list`, or `--disable`. Default is auto-detect.

### 2. Read the registry

```bash
yq -o=json '.lsps' ~/Dev/dotfiles/claude/plugins/lsp-registry.yaml
```

This gives you the full LSP map: plugin names, descriptions, and extension lists.

### 3. Detect languages (skip if `--all` or `--disable`)

For each LSP in the registry, check if any matching files exist in the project.
Use Glob with patterns like `**/*.py`, `**/*.ts`, etc. — one glob per extension set.
Stop checking an LSP's extensions as soon as you find a match (short-circuit).

Ignore common vendored/generated directories: `node_modules`, `vendor`, `.git`,
`dist`, `build`, `target`, `__pycache__`, `.venv`, `venv`.

### 4. Build the enabledPlugins object

Construct a JSON object mapping matched LSP plugin names to `true`:

```json
{
  "pyright@claude-code-lsps": true,
  "vtsls@claude-code-lsps": true
}
```

### 5. Report findings

Show the user what was detected:

```
Detected languages:
  Python (.py)     → pyright
  TypeScript (.ts) → vtsls

Skipped (no files found):
  Go, Rust, Ruby, Bash, YAML
```

If `--list`, stop here. Do not write anything.

### 6. Write to local settings

Read `~/.claude/settings.local.json` (create `{}` if missing).
Merge the LSP entries into `enabledPlugins`, preserving all existing entries.

```bash
jq --argjson lsps '$ENABLED_JSON' \
  '.enabledPlugins = (.enabledPlugins // {}) + $lsps' \
  ~/.claude/settings.local.json > /tmp/claude-settings-tmp.json \
  && mv /tmp/claude-settings-tmp.json ~/.claude/settings.local.json
```

For `--disable`, remove all registry LSP keys from `enabledPlugins` instead:

```bash
jq --argjson keys '["pyright@claude-code-lsps", ...]' \
  '.enabledPlugins = (.enabledPlugins // {} | to_entries | map(select(.key as $k | $keys | index($k) | not)) | from_entries)' \
  ~/.claude/settings.local.json > /tmp/claude-settings-tmp.json \
  && mv /tmp/claude-settings-tmp.json ~/.claude/settings.local.json
```

### 7. Remind about restart

Tell the user to restart Claude Code for changes to take effect, or that
the LSPs will be active on next session start.

## Edge cases

- **No languages detected**: Report this clearly. Don't write an empty object.
  Suggest `--all` if the user wants everything.
- **settings.local.json doesn't exist**: Create it with `{}` first.
- **Already enabled**: If all detected LSPs are already enabled, say so and skip the write.
- **Mixed state**: If some LSPs are enabled and new ones are detected, merge — don't overwrite.
