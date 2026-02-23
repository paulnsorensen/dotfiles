---
name: serena
model: sonnet
allowed-tools: mcp__serena__*
description: >
  Semantic code analysis using Serena MCP — symbol lookup, cross-reference
  tracing, code navigation, and memory persistence across compaction. Use
  when navigating or understanding the current codebase structure. Prefer
  over grep/glob for anything structural ("what implements X?", "who calls Y?").
  Also handles project activation and session memory management.
---

# serena

Semantic code navigation and project memory. Only use via this skill.

## Activate first

Always start a new session with:
1. `activate_project` — load the current project
2. `check_onboarding_performed` — run onboarding if not yet done
3. `list_memories` + `read_memory` — restore session context

## Core tools

| Task | Tool |
|------|------|
| Get overview of symbols in a file | `get_symbols_overview` |
| Find a specific symbol | `find_symbol` |
| Find all usages of a symbol | `find_referencing_symbols` |
| Navigate file structure | `list_dir`, `find_file` |
| Search for a pattern | `search_for_pattern` |
| Replace a whole symbol body | `replace_symbol_body` |
| Add code before/after a symbol | `insert_before_symbol`, `insert_after_symbol` |
| Save a discovery across sessions | `write_memory` |
| Read persisted context | `read_memory`, `list_memories` |

## Navigation pattern

1. `get_symbols_overview` or `find_symbol(include_body=False)` to orient
2. `find_symbol(include_body=True)` only for symbols you need to read or edit
3. `find_referencing_symbols` for impact analysis before editing
4. Avoid `read_file` unless a file has no symbols (config, data files)

## search_for_pattern

For text/regex searches when you don't have a symbol name:

```
# Code-only search (skips configs, data files, markdown)
search_for_pattern(substring_pattern="validate_.*input", restrict_search_to_code_files=True)

# Narrow scope to a directory
search_for_pattern(substring_pattern="Repository", relative_path="src/adapters/")

# Get surrounding context for matches
search_for_pattern(substring_pattern="raise.*Error", context_lines_before=3, context_lines_after=3)

# Exclude test files
search_for_pattern(substring_pattern="def create_user", paths_exclude_glob="*test*")
```

### When to use which search

| Need | Tool |
|------|------|
| Who calls/uses a known symbol? | `find_referencing_symbols` |
| Text/regex match without a symbol name | `search_for_pattern` |
| Search config, YAML, markdown, data files | `search_for_pattern` |
| Impact analysis before editing a symbol | `find_referencing_symbols` |

## Memory

Write memories for discoveries worth keeping across compaction:

**Worth persisting:**
- Architecture decisions and domain boundary maps
- Key file ownership (which team/module owns what)
- Gotchas that cost debugging time
- Conventions not captured in CLAUDE.md or onboarding

**Not worth persisting:**
- Current task state (use `/park` instead)
- File contents you just read (they're in the codebase)
- Anything already in CLAUDE.md or onboarding docs
