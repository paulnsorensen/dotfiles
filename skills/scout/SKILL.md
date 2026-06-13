---
name: scout
model: haiku
allowed-tools: Skill, Bash(ls:*)
description: >
  Filesystem exploration with human-friendly eza tree views and git status;
  delegates content/code search to cheez-search (AST-aware via tilth). Use when
  the user says "search files", "find by metadata", "tree view", "list directory
  with git status", or invokes /scout. Do NOT use for symbol, usage, or
  structural code search — that's cheez-search.
---

# scout

Filesystem exploration skill. **All code/content search is delegated to
`easy-cheese:cheez-search`** (AST-aware tilth MCP). The only thing scout
itself owns is `ls` (eza) — directory listings with git status and tree views.

## When to use which

| Task | Tool |
|------|------|
| Find a definition / usage / caller | `Skill(skill="easy-cheese:cheez-search", args="...")` |
| Find files by name, extension, type | `Skill(skill="easy-cheese:cheez-search", args="...")` (with `glob:` filter) |
| Read a file you've located | `Skill(skill="easy-cheese:cheez-read", args="...")` |
| Tree view of a directory | `ls -T -L 2` (eza) |
| Long listing with git status | `ls -la --git` (eza) |

## Delegation contract

Any time you would have reached for `rg`, `fd`, or `grep`, invoke
`easy-cheese:cheez-search` instead. It uses tilth MCP for tree-sitter
structural matching, finds definitions before usages, and returns ranked
results with inline source.

```
Skill(skill="easy-cheese:cheez-search", args="<symbol or text> [glob:*.ts]")
```

If `mcp__tilth__*` is unavailable (tilth MCP not loaded or daemon down),
cheez-search will hard-fail. Surface that error to the user — do not fall
back to raw `rg`/`fd` from this skill.

## ls — eza (aliased)

`ls` is aliased to `eza` — color-aware ls replacement with `--git` status
column and tree view (`-T`).

### Common patterns

```bash
ls -T -L 2                  # tree view, 2 levels deep
ls -T -L 3 --dirs-first     # tree, dirs first, 3 levels
ls -la --git                # long listing with git status
```

## What you don't do

- Edit or modify files — use `easy-cheese:cheez-write`
- Read file contents — use `easy-cheese:cheez-read`
- Search code structure or text — use `easy-cheese:cheez-search`
- Fetch external docs — use Context7 directly or `/briesearch`

## Gotchas

- `eza` may not be available in sub-agent contexts — falls back to plain `ls`
- cheez-search requires the tilth MCP server (provided by cheese-flow plugin)
