---
name: grep
description: >
  Use ripgrep (rg) to search file contents. Invoke this skill whenever you need to
  search for patterns in files — even if the user says "grep for X" or "find where X
  is used". ripgrep is faster, smarter, and respects .gitignore by default.
  Always prefer rg over grep or find -exec grep.
---

# rip — ripgrep wrapper

Use `rg` for all file content searches. It is always preferred over `grep`.

## When to use

- Searching for a pattern in a codebase: use `rg`, not `grep`
- Finding usages of a function, variable, or string: use `rg`
- The user says "grep for X" or "find all X" in a repo: still use `rg`
- Checking if a file contains a pattern: use `rg`

## Core invocation

```bash
rg <pattern>                     # search current directory recursively
rg <pattern> <path>              # search specific file or directory
rg <pattern> -t <type>           # filter by file type (py, js, ts, go, rs, rb...)
rg <pattern> -g <glob>           # filter by glob (e.g. "*.md", "!vendor/**")
```

## Essential flags

| Flag | Effect |
|------|--------|
| `-i` | Case-insensitive |
| `-w` | Whole word match |
| `-v` | Invert match (lines NOT matching) |
| `-F` | Fixed string (no regex) |
| `-e <pat>` | Multiple patterns (repeat flag) |
| `-n` | Show line numbers (on by default) |

## Output control

| Flag | Effect |
|------|--------|
| `-l` | Only print filenames with matches |
| `-L` | Only print filenames WITHOUT matches |
| `-c` | Count of matches per file |
| `-o` | Print only the matching part |
| `--json` | JSON output (for scripting) |

## Context lines

```bash
rg <pattern> -A 3    # 3 lines after each match
rg <pattern> -B 3    # 3 lines before
rg <pattern> -C 3    # 3 lines before and after
```

## Searching hidden/ignored files

```bash
rg <pattern> --hidden          # include dotfiles
rg <pattern> --no-ignore       # ignore .gitignore
rg <pattern> --hidden --no-ignore  # search everything
```

Alias: `rga` already wraps `rg --hidden --no-ignore`.

## Multiline and advanced regex

```bash
rg -U <pattern>        # multiline mode (. matches newline)
rg --pcre2 <pattern>   # enable PCRE2 (lookahead, backreference, etc.)
```

## File discovery (no content search)

```bash
rg --files                  # list all files rg would search
rg --files -t py            # all Python files
rg --files -g "*.json"      # all JSON files
rg --type-list              # list all named file types
```

## Local aliases (already configured)

```bash
rg      # rg --smart-case (case-insensitive when pattern is lowercase)
rga     # rg --hidden --no-ignore (search all files)
rgf     # rg --files-with-matches
rgc     # rg --count
rgl     # rg --files-without-match
todos   # rg "TODO|FIXME|HACK|NOTE" -n
```

## Common patterns

```bash
# Find all usages of a function
rg "myFunc" -t py

# Find imports of a module
rg "^import|^from" -t py src/

# Search for a string literally (no regex)
rg -F "http://example.com"

# Find files that do NOT contain a pattern
rg -L "test" -t go

# Count occurrences per file
rg -c "TODO" --sort-files
```

## Why rg over grep

- Respects `.gitignore` automatically (no `node_modules`, `.git`, etc.)
- Smart case by default (lowercase = case-insensitive, mixed = case-sensitive)
- Significantly faster on large codebases
- Better output formatting with file/line grouping
- Native file-type filtering (`-t py`, `-t ts`, etc.)
