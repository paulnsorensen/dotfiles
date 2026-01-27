# Setup Project Permissions

Scaffold a clean `.claude/settings.local.json` with sensible permissions for this project.

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

2. **Determine the project root** using the current working directory (the absolute path where Claude Code is running). This path is used to scope destructive commands. Refer to it as `$PWD` below.

3. **Build the allow list** by combining layers. Start with the base layer, then add each detected type's layer.

Commands are split into two categories:
- **Safe (read-only / non-destructive):** unscoped, can run anywhere
- **Destructive (writes / moves / deletes):** scoped to `$PWD/*` so they only work inside the project

**Base (always included):**
```
# Safe — unscoped
Bash(git *)
Bash(ls *)
Bash(cat *)
Bash(head *)
Bash(tail *)
Bash(wc *)
Bash(which *)
Bash(echo *)
Bash(grep *)
Bash(find *)
Bash(diff *)
Bash(sort *)
Bash(tr *)
Bash(test *)
Bash([ *)
Bash(true)
Bash(false)
Bash(gh *)

# Destructive — scoped to project
Bash(mkdir $PWD/*)
Bash(mv $PWD/*)
Bash(cp $PWD/*)
Bash(chmod $PWD/*)
Bash(sed $PWD/*)
Bash(awk $PWD/*)
Bash(xargs $PWD/*)

# MCP & web
mcp__serena__*
mcp__octocode__*
WebSearch
```

**IMPORTANT:** Replace `$PWD` with the actual absolute path (e.g. `/Users/paulsorensen/Dev/dotfiles`). Do NOT leave `$PWD` as a literal string in the output.

**Dotfiles/shell layer:**
```
Bash(bash *)
Bash(sh *)
Bash(zsh *)
Bash(source *)
Bash(shellcheck *)
Bash(brew *)
Bash(yq *)
Bash(jq *)
Bash(bats *)
Bash(tinty *)
Bash(home-manager *)
Bash(nix *)
Bash(plutil *)
Bash(claude *)
Bash(python3 *)
Bash(alias *)
```

**Node/TS layer:**
```
Bash(npm *)
Bash(npx *)
Bash(node *)
Bash(pnpm *)
Bash(yarn *)
Bash(tsc *)
Bash(eslint *)
Bash(prettier *)
Bash(jest *)
Bash(vitest *)
```

**Python layer:**
```
Bash(uv *)
Bash(python *)
Bash(python3 *)
Bash(pytest *)
Bash(mypy *)
Bash(ruff *)
```

**Rust layer:**
```
Bash(cargo *)
Bash(rustc *)
Bash(rustup *)
```

**Go layer:**
```
Bash(go *)
Bash(gopls *)
```

**Ruby layer:**
```
Bash(bundle *)
Bash(ruby *)
Bash(gem *)
Bash(rake *)
```

3. **Read existing `.claude/settings.local.json`** and extract the `enabledMcpjsonServers` array if present. Preserve it in the output.

4. **Write `.claude/settings.local.json`** with this structure:
```json
{
  "permissions": {
    "allow": [/* merged, deduplicated, sorted permissions */],
    "deny": []
  },
  "enabledMcpjsonServers": [/* preserved from existing file */]
}
```

5. **Print a summary** like:
```
Detected: dotfiles, python
Permissions: 45 rules (base: 27, dotfiles: 16, python: 6)
Preserved: 4 MCP servers
Wrote: .claude/settings.local.json
```

## Important

- Overwrite the entire `permissions` block — do NOT merge with old accumulated permissions
- DO preserve `enabledMcpjsonServers` from the existing file
- Sort the allow list alphabetically for readability
- Use `settings.local.json` (gitignored), never `settings.json`
- The `deny` array should always be empty — hooks handle blocking
