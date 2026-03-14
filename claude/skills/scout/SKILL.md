---
name: scout
model: haiku
allowed-tools: Bash(rg:*), Bash(fd:*), Bash(ls:*)
description: >
  Use rg, fd, and ls (eza) to search and explore files. Adds capabilities
  beyond built-in Grep/Glob: fd finds files by metadata (size, date, type),
  rg aliases (rga, rgf, rgc, todos) provide common search patterns, and
  ls (eza) gives tree views with git status. Use built-in Grep/Glob for
  simple content/name searches; use scout when you need fd, rg aliases,
  hidden/ignored file search, or eza directory listings.
---

# scout

Search and explore the filesystem. Three tools, one skill.

## When to use which tool

| Task | Tool |
|------|------|
| Search file contents for a pattern | `rg` |
| Find files by name or extension | `fd` |
| List directory contents | `ls` (eza) |
| The user says "grep for X" | `rg` |
| The user says "find files named X" | `fd` |
| Enumerate a directory structure | `ls` |

---

## rg — ripgrep

Search file contents. Respects `.gitignore` by default. Smart-case by default
(case-insensitive when pattern is all lowercase).

### Searching hidden/ignored files

```bash
rg <pattern> --hidden          # include dotfiles
rg <pattern> --no-ignore       # ignore .gitignore
rg <pattern> --hidden --no-ignore  # search everything
```

### Local aliases

Defined in `zsh/aliases.zsh` — if aliases change there, update references here.

```bash
rg      # rg --smart-case
rga     # rg --hidden --no-ignore (search all files)
rgf     # rg --files-with-matches
rgc     # rg --count
rgl     # rg --files-without-match
todos   # rg "TODO|FIXME|HACK|NOTE" -n
```

---

## fd — file finder

Find files by name, extension, or type. Faster than `find`. Respects `.gitignore`.
Pattern is a regex matched against the filename (not full path by default).

### Common patterns

```bash
fd -e ts                    # all .ts files
fd -e md -e txt             # multiple extensions
fd -t f                     # files only (no directories)
fd -t d                     # directories only
fd -E node_modules -E dist  # exclude directories
fd 'test_.*\.py$'           # regex: Python test files
fd -H .env                  # include hidden files
```

---

## ls — eza (aliased)

`ls` is aliased to `eza` — a modern, color-aware ls replacement with `--git`
status column and tree view (`-T`).

### Common patterns

```bash
ls -T -L 2                  # tree view, 2 levels deep
ls -T -L 3 --dirs-first     # tree, dirs first, 3 levels
ls -la --git                # long listing with git status
```
