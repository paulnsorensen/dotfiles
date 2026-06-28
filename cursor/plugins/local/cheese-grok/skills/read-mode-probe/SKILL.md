---
name: read-mode-probe
description: Use when the user wants to interrogate an unfamiliar codebase with structured probes rather than a summary — invariants, data flow, error paths, hot paths, security surface. Triggers on "probe this", "what are the invariants here", "where does X flow", "find the risk in this code", "trace error paths", "what's on the hot path", "security audit this file/module", "what could go wrong here". Returns numbered findings with confidence + citations, never edits.
allowed-tools: read_file, codebase_search, find_symbol, mcp__serena__find_symbol, mcp__serena__find_referencing_symbols, mcp__serena__get_symbols_overview, mcp__serena__search_for_pattern, mcp__tilth__tilth_search, mcp__tilth__tilth_read, mcp__tilth__tilth_grok, mcp__tilth__tilth_deps
metadata:
  version: 0.1.0
  author: paulnsorensen
  last-updated: 2026-05-22
---

# read-mode-probe — Five probes, one stance

Reader-first. **No edits.** Pick the probe closest to the user's question;
if ambiguous, ask. Output is a numbered list of findings tagged with
confidence (`high` / `med` / `low`) and a file:line citation, followed by
a "next probes I would run" closer.

## The five probes

### 1. Invariant probe

List the things that must always be true in this code, and cite *where*
they're enforced. Catalog what would happen if each invariant were
violated (silent corruption? hard panic? rejected request?).

Tool order:

1. `mcp__serena__find_symbol` for the central type/function.
2. `mcp__tilth__tilth_grok` to pull its callers + tests in one shot.
3. `mcp__serena__find_referencing_symbols` to find every check site.

### 2. Data-flow probe

Trace a value — a user-id, a request body, an env var, a feature flag —
from its entry point to its persistence or external use. Name every
file:line where the value is read, transformed, or written.

Tool order:

1. `mcp__tilth__tilth_search` (kind=content) for the literal name.
2. `mcp__serena__find_referencing_symbols` on each definition site.
3. `mcp__tilth__tilth_deps` / `mcp__tilth__tilth_grok` (callees) for the
   downstream reach.

### 3. Error-path probe

For a given function or module, enumerate every `throw`, `return Err`,
`panic`, `reject`, or unhandled rejection. For each: where it can be
triggered, who catches it (if anyone), and whether it's recoverable
or terminal.

Tool order:

1. `mcp__tilth__tilth_grok(target=<function>)` for body + callers.
2. `mcp__tilth__tilth_search(query="catch,try,Result,Err,panic,throw,reject")`
   to find the surrounding error machinery.

### 4. Hot-path probe

Find loops, N+1 queries, sync I/O on request paths, and unbounded
allocations. Sort findings by likely impact — flag the worst offender
first.

Tool order:

1. `mcp__serena__find_referencing_symbols` for high-fan-in functions.
2. `mcp__tilth__tilth_grok` / `mcp__tilth__tilth_read` to spot >150-LOC
   bodies.
3. `mcp__tilth__tilth_search(query="forEach,for.*await,await.*for,for.*\\.length")`
   for common loop antipatterns.

### 5. Security probe

Audit input validation, authz checks, secret handling, deserialization
sinks, SQL/shell injection vectors, SSRF, prototype pollution.

Tool order:

1. `mcp__tilth__tilth_search(query="JSON.parse,eval,exec,Function,vm,child_process,spawn")`
   for deserialization + exec sinks.
2. `mcp__tilth__tilth_search(query="req.body,req.params,req.query,process.argv")`
   for untrusted-input entry points.
3. `mcp__serena__find_referencing_symbols` to walk from each input
   to where it's used.

## Output template

```
## Findings (<probe-name> probe on <target>)

1. [high] <finding> — `path/to/file.ts:42`
   <one-sentence why this matters>

2. [med] <finding> — `path/to/file.ts:88`
   <one-sentence why this matters>

...

## Next probes I would run

- <name>: <one-sentence reason>
- <name>: <one-sentence reason>
```

## Hard rules

1. **Every finding has a file:line citation.** No "looks like" or
   "appears to" — quote the line if needed.
2. **Confidence tags are mandatory.** `high` = verified by reading the
   exact code. `med` = pattern-matched but not fully traced.
   `low` = suspicious, worth checking but not confirmed.
3. **No edits, no refactor suggestions.** If the user asks "how should
   we fix this?", reply: "Switch out of read-mode-probe. Want me to
   propose a fix?" — and wait.
4. **Reader-first verbs only.** `read_file`, `codebase_search`,
   `find_symbol`, `mcp__serena__*`, `mcp__tilth__*` (no `tilth_write`).
   No `edit_file`, no `run_terminal_cmd` except `git log|status|diff|show`,
   `ls`, `wc`.
