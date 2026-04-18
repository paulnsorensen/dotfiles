---
name: lookup
model: haiku
description: >
  Code intelligence router — decides which tool to use when you need to understand
  a symbol, type, API, or code relationship. Language-agnostic: works for Rust,
  Python, TypeScript, Go, Ruby, Java, and any language tilth/tree-sitter parses.
  Prevents wasteful brute-force lookup anti-patterns: cargo doc + grep, grepping
  dependency caches (node_modules, site-packages, .cargo/registry, go/pkg/mod,
  .m2), go doc + grep, python help() + grep, and multi-step find chains. Use this
  skill BEFORE reaching for bash when the question is "what does X do?", "what's
  the signature of Y?", "who calls Z?", or "how do I use this API?". Routes to
  the right tool: tilth_search for structural patterns (symbol, regex, callers)
  as the default; `/explore` (cheese-flow:explore-lsp) for type-aware planning
  queries; Context7 for external docs; octocode for GitHub code search. Direct
  LSP tool calls are disallowed outside the cheese-flow explore flow — this skill
  will route you to `/explore` when planning needs type precision. If you catch
  yourself about to grep a dependency cache, generate docs just to search them,
  or fire the raw LSP tool — stop and use this instead.
---

# lookup

Code intelligence routing. Ask the right tool, not bash.

When you need to understand a symbol, type, or API, your instinct might be to
grep for it, run `cargo doc`, or read files in `node_modules`. Don't. You have
four purpose-built tools that are faster, cheaper, and don't pollute your context.
This skill tells you which one to use.

> **LSP is planning-only.** Direct calls to the `LSP` tool from the main session
> or agents are disallowed. When the answer genuinely requires type resolution
> (planning a refactor, building a change plan for an unfamiliar flow), invoke
> `/explore` — its `cheese-flow:explore-lsp` sub-agent is the one sanctioned LSP
> consumer. For review, verification, and day-to-day navigation, `tilth_search`
> is the default.
>
> **Read in batches.** When you know you need more than one file, issue a single
> `tilth_read(paths: [a, b, c])` call. Sequential one-off reads are an
> anti-pattern this skill exists to route away from.

## Decision Tree

Ask yourself two questions:

### 1. Is the code LOCAL (in this project) or EXTERNAL (a dependency)?

### 2. What do I need to know?

Then follow the table:

| What I need | Local code (default) | Planning needs types (delegate) | External dependency |
|---|---|---|---|
| Type/signature of a symbol | **tilth_search** `kind: symbol, expand: 1` | `/explore` → explore-lsp `hover` | **Context7** or **octocode** |
| Go to definition | **tilth_search** `kind: symbol` | `/explore` → explore-lsp `goToDefinition` | **Context7** `query-docs` |
| Who calls this function? | **tilth_search** `kind: callers` | `/explore` → explore-lsp `findReferences` | **octocode** `search_code` |
| Who implements this trait/interface? | **tilth_search** `kind: symbol` | `/explore` → explore-lsp for type-resolved impls | **octocode** `search_code` |
| All usages of a type | **tilth_search** `kind: symbol` or `kind: callers` | `/explore` → explore-lsp `findReferences` | **octocode** `search_code` |
| Method list on a struct/class | **tilth_search** `kind: symbol` on the type | `/explore` → explore-lsp `documentSymbol` | **Context7** `query-docs` |
| What does this function do? | **tilth_read(paths: [...])** with `section:` + **tilth_search** `expand` | — | **Context7** or **WebFetch** raw source |
| Find structural patterns | **tilth_search** `kind: symbol` or `kind: regex` | — | N/A — use octocode text search |
| Error type / return type | **tilth_search** `kind: symbol, expand: 1` on the signature | `/explore` → explore-lsp `hover` when inferred | **Context7** `query-docs` |
| Find files by name/pattern | **tilth_files** (glob, gitignore-aware) | — | N/A |
| Find files by content | **tilth_search** `kind: content` or `kind: regex` | — | **octocode** `search_code` |
| List directory contents | **tilth_files** `pattern: *` | — | **octocode** `view_repo_structure` |
| Read multiple files for editing | **tilth_read(paths: [a, b, c])** — always batch | — | N/A |

"Delegate" means you stop and spawn `/explore` — you do not call the `LSP` tool
directly. Use it when tilth_search cannot resolve the answer because the
question is fundamentally about inferred types, overloads, or type-aware
references (e.g., trait dispatch, generics, TypeScript narrowing).

### Quick reference by tool

**tilth_search** (MCP, AST-aware — zero config, the default):

- `kind: symbol` — finds definitions and usages by symbol name (AST-based, not text)
- `kind: content` — literal text search across files
- `kind: regex` — PCRE2 regex search
- `kind: callers` — all call sites of a symbol
- `expand: N` — inline top N match source bodies directly in results
- Best for: "what implements X?", "who calls Y?", "find all uses of Z"

**tilth_read** (MCP, smart reader — batch by default):

- `tilth_read(paths: [a, b, c])` — batch multiple files in one call (preferred)
- `tilth_read(path, section: "45-89")` — line-range slice with hashline anchors
- `tilth_read(path, section: "## Heading")` — markdown heading slice
- `tilth_read(path, full: true)` — force full content for short files
- **NEVER use `Read`/`cat`/`head`/`tail`** — use `tilth_read` instead.

**tilth_files** (MCP, file discovery):

- `tilth_files(pattern: "**/*.ts")` — glob with token estimates, gitignore-aware
- **NEVER use `find`** — use tilth_files instead. `find` is blocked by hook.

**cheese-flow:explore-lsp** (via `/explore` skill — planning-only LSP broker):

- Wraps `hover`, `goToDefinition`, `findReferences`, `documentSymbol`,
  `workspaceSymbol`, `callHierarchy` behind a short-lived sub-agent.
- Sanctioned use cases: planning a refactor, deriving a change plan, mapping
  type-resolved flows when the graph/tilth answer is ambiguous.
- **Do not call the `LSP` tool directly** — `/explore` is the entry point.

**Context7** (MCP, for external libraries):

- `resolve-library-id` → `query-docs` — version-specific docs + examples
- Best for: "what's the API of portable-pty?", "how does serde derive work?"

**octocode** (MCP, GitHub code search):

- `search_code` — find implementations across public repos
- Best for: "how do people use this API?", "show me examples of X"

## Anti-Patterns — NEVER Do These

These are the brute-force patterns this skill exists to prevent:

### 1. Doc generation + grep (any language)

```bash
# WRONG — Rust
cargo doc -p some-crate --no-deps 2>&1; grep -r "fn method" target/doc/

# WRONG — Go
go doc some/package | grep "func Method"

# WRONG — Python
python3 -c "help(some_module)" 2>&1 | grep "method_name"
pydoc some.module | grep "def method"

# WRONG — Ruby
ri SomeClass | grep "method_name"
```

**Instead**: Context7 `query-docs` for the library, or octocode to search the repo.

### 1a. Direct `LSP` tool calls

```
LSP findReferences ...
LSP hover ...
```

**Wrong unless you are inside `cheese-flow:explore-lsp`.** Direct LSP use is
gated to planning-only and routed through `/explore`. For review or
verification, use `tilth_search kind: callers` or `kind: symbol`. For planning,
invoke `/explore` and let the explore-lsp sub-agent run LSP.

### 2. Grepping dependency caches (any ecosystem)

```bash
# WRONG — Rust
grep -r "fn env" ~/.cargo/registry/src/*/portable-pty-*/

# WRONG — JavaScript/TypeScript
grep -r "interface Props" node_modules/react/

# WRONG — Python
grep -r "def validate" .venv/lib/python3.*/site-packages/pydantic/

# WRONG — Go
grep -r "func New" ~/go/pkg/mod/github.com/some/pkg@*/

# WRONG — Java
grep -r "public void" ~/.m2/repository/org/some/artifact/

# WRONG — Ruby
grep -r "def method" vendor/bundle/ruby/*/gems/some-gem-*/
```

**Instead**: `tilth_search kind: symbol` on the usage site, or Context7 for the docs.

### 3. Multi-step find + grep chains

```bash
# WRONG — O(n) scanning for what's an O(1) lookup
find . -name "*.rs" | xargs grep "trait CommandBuilder"
grep -rn "def validate" --include="*.py" | grep -v test
find . -path "*/some_crate*" -exec grep "fn method" {} \;
```

**Instead**: `tilth_search kind: symbol, query: 'CommandBuilder'` (or `kind: callers` for call sites).

### 4. Building code to discover types

```bash
# WRONG — compiling just to read error messages for type info
cargo check 2>&1 | grep "expected"
tsc --noEmit 2>&1 | grep "Type '"
mypy src/ 2>&1 | grep "has type"
```

**Instead**: `tilth_search kind: symbol, expand: 1` on the signature. If the
type is truly inferred and you're *planning a refactor*, invoke `/explore` and
let `cheese-flow:explore-lsp` run the `hover` query.

### 5. Reading entire files for one signature

```bash
# WRONG — loading 500 lines to find one function
cat src/lib.rs | grep -A 20 "fn new"
```

**Instead**: `tilth_search kind: symbol, expand: 1` on the signature. For
multi-file inspection, batch the reads: `tilth_read(paths: [a, b, c], section: "...")`.

### 6. Serial single-file reads when a batch would do

```
tilth_read(path: "a.rs")
tilth_read(path: "b.rs")
tilth_read(path: "c.rs")
```

**Instead**: `tilth_read(paths: ["a.rs", "b.rs", "c.rs"])` — one call, one
context hit. Serial reads are only correct when the second path genuinely
depends on what you learned from the first.

## When Tools Aren't Available

Not every project has all tools active:

| Situation | Fallback |
|---|---|
| Planning question tilth_search can't resolve | `/explore` (cheese-flow:explore-lsp) — planning-only LSP broker |
| cheese-flow plugin not installed | tilth_search kind:symbol + kind:callers is usually sufficient for review/verification |
| Context7 doesn't have the library | octocode search → WebFetch raw source |
| External crate, no MCP available | `WebSearch` for official docs (via /fetch skill) |

The hierarchy is: **tilth_search > /explore (cheese-flow:explore-lsp) > Grep**.
Tilth is the default. `/explore` is the sanctioned escalation when planning
genuinely needs type precision. Grep is only used when none of the above apply.

## Why This Skill Is NOT Forked

This skill runs inline — not in a sub-agent — because routing is cheap. The
skill's output is a decision ("use tilth_search kind: callers" or "invoke
/explore"), not verbose data. There's nothing to isolate from the context
window.

The tools this skill routes TO may fork on their own (`/explore` forks four
sub-agents, `/fetch` forks for Context7/octocode). That's fine — the routing
decision stays inline, the heavy lifting forks as needed.

## Rules

- Route FIRST, execute SECOND — decide which tool before running anything
- One lookup per question — don't chain 3 tools when one gives the answer
- External deps are NEVER solved by grepping local caches
- **Never invoke the `LSP` tool directly.** If the answer truly needs type
  inference, invoke `/explore` instead.
- **Batch reads by default.** Multi-file reads use `tilth_read(paths: [...])`,
  not sequential calls.
- If you need the skill that each tool delegates to, invoke it: /explore, /fetch

## Gotchas

- Context7 library ID resolution sometimes returns wrong package for ambiguous names — verify
- tilth_search patterns are language-agnostic (regex/content) or AST-aware (symbol/callers) — use `kind: symbol` for structural queries
- tilth_read's smart outlining suppresses symbol bodies in large files — use `section:` or `full: true` when you need the body
- Training data is often sufficient for well-known libraries — don't fetch docs for stdlib
- `/explore` takes ~30s for the four sub-agents to return — only escalate when tilth_search genuinely can't answer, not as a warm-up
