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

## Memory

Write memories for discoveries worth keeping across compaction:
- Key architecture decisions and domain model locations
- Patterns and conventions specific to this project
- Solutions to recurring problems

Do not write: session-specific state, in-progress work, or anything
already captured in CLAUDE.md.
