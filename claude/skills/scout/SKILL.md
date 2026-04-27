---
name: scout
model: haiku
allowed-tools: Skill, Bash(ls:*)
description: >
  Filesystem exploration. Delegates content/code search to cheese-flow's
  cheez-search (AST-aware via tilth MCP). Keeps eza directory listings for
  human-friendly tree views with git status. Use when the user says "search
  files", "find by metadata", "tree view", "list directory with git status",
  or invokes /scout. For symbol/usage/structural search, the work is done by
  cheez-search — this skill is a thin pointer.
---

# scout

Filesystem exploration skill. **All code/content search is delegated to
`cheese-flow:cheez-search`** (AST-aware tilth MCP). The only thing scout
itself owns is `ls` (eza) — directory listings with git status and tree views.

## When to use which

| Task | Tool |
|------|------|
| Find a definition / usage / caller | `Skill(skill="cheese-flow:cheez-search", args="...")` |
| Find files by name, extension, type | `Skill(skill="cheese-flow:cheez-search", args="...")` (with `glob:` filter) |
| Read a file you've located | `Skill(skill="cheese-flow:cheez-read", args="...")` |
| Tree view of a directory | `ls -T -L 2` (eza) |
| Long listing with git status | `ls -la --git` (eza) |

## Delegation contract

Any time you would have reached for `rg`, `fd`, or `grep`, invoke
`cheese-flow:cheez-search` instead. It uses tilth MCP for tree-sitter
structural matching, finds definitions before usages, and returns ranked
results with inline source.

```
Skill(skill="cheese-flow:cheez-search", args="<symbol or text> [glob:*.ts]")
```

If `mcp__tilth__*` is unavailable (cheese-flow plugin disabled or daemon down),
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

- Edit or modify files — use `cheese-flow:cheez-write`
- Read file contents — use `cheese-flow:cheez-read`
- Search code structure or text — use `cheese-flow:cheez-search`
- Fetch external docs — use `/fetch`

## Gotchas

- `eza` may not be available in sub-agent contexts — falls back to plain `ls`
- cheez-search requires the tilth MCP server (provided by cheese-flow plugin)
