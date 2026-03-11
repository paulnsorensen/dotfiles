---
name: lookup
description: >
  Code intelligence router — decides which tool to use when you need to understand
  a symbol, type, API, or code relationship. Language-agnostic: works for Rust,
  Python, TypeScript, Go, Ruby, Java, and any language with LSP support. Prevents
  wasteful brute-force lookup anti-patterns: cargo doc + grep, grepping dependency
  caches (node_modules, site-packages, .cargo/registry, go/pkg/mod, .m2),
  go doc + grep, python help() + grep, and multi-step find chains. Use this skill
  BEFORE reaching for bash when the question is "what does X do?", "what's the
  signature of Y?", "who calls Z?", or "how do I use this API?". Routes to the
  right tool: LSP for types, Serena for cross-refs, ast-grep for structural
  patterns, Context7 for external docs, octocode for GitHub code search. If you
  catch yourself about to grep a dependency cache or generate docs just to search
  them — stop and use this instead.
---

# lookup

Code intelligence routing. Ask the right tool, not bash.

When you need to understand a symbol, type, or API, your instinct might be to
grep for it, run `cargo doc`, or read files in `node_modules`. Don't. You have
five purpose-built tools that are faster, cheaper, and don't pollute your context.
This skill tells you which one to use.

## Decision Tree

Ask yourself two questions:

### 1. Is the code LOCAL (in this project) or EXTERNAL (a dependency)?

### 2. What do I need to know?

Then follow the table:

| What I need | Local code | External dependency |
|---|---|---|
| Type/signature of a symbol | **LSP** `hover` | **Context7** or **octocode** |
| Go to definition | **LSP** `goToDefinition` | **Context7** `query-docs` |
| Who calls this function? | **Serena** `find_referencing_symbols` | **octocode** `search_code` |
| Who implements this trait/interface? | **/trace** `sg -p 'impl $T for $S'` | **octocode** `search_code` |
| All usages of a type | **Serena** `find_referencing_symbols` | **octocode** `search_code` |
| Method list on a struct/class | **LSP** `documentSymbol` | **Context7** `query-docs` |
| What does this function do? | **LSP** `hover` + **Read** the body | **Context7** or **WebFetch** raw source |
| Find structural patterns | **/trace** `sg --lang X -p 'pattern'` | N/A — use octocode text search |
| Error type / return type | **LSP** `hover` | **Context7** `query-docs` |
| Find files by name/pattern | **Glob** or **fd** (scout skill) | N/A |
| Find files by content | **Grep** (built-in) or **rg** (scout) | **octocode** `search_code` |
| List directory contents | **ls** (scout skill) | **octocode** `view_repo_structure` |

### Quick reference by tool

**LSP** (built-in tool, zero setup):
- `hover` — type signature, docs, return type
- `goToDefinition` — jump to where it's defined
- `findReferences` — all usages in the project
- `documentSymbol` — list all symbols in a file
- Works on: .rs, .py, .ts, .go, .sh, .yaml, .rb (all 7 LSP plugins)

**Serena** (MCP, needs activation):
- `find_symbol` — locate by name, optionally include body
- `find_referencing_symbols` — cross-file usage analysis
- `get_symbols_overview` — file-level symbol map
- Best for: "who calls X?", "what references Y?", impact analysis

**ast-grep** (zero config — invoke via `/trace` skill):
- `sg --lang X -p 'pattern'` — structural pattern matching
- Best for: "find all classes that extend Z", "which functions have >4 params"
- Works on AST shape, not text — won't false-match comments or strings
- **Always use `/trace`** — it enforces no-file-read and proper output format

**File finding** (built-in tools or scout skill):
- **Glob** — find files by name/extension pattern (`**/*.ts`, `src/**/*.rs`)
- **fd** (via scout) — find files by name, type, size, date (`fd -e rs -t f`)
- **Grep** (built-in) — search file contents for text patterns
- **rg** (via scout) — faster content search with .gitignore awareness
- **NEVER use `find`** — use Glob or fd instead. `find` is blocked by hook.

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
**Instead**: LSP `hover` on the symbol where you use it, or Context7 for the docs.

### 3. Multi-step find + grep chains
```bash
# WRONG — O(n) scanning for what's an O(1) lookup
find . -name "*.rs" | xargs grep "trait CommandBuilder"
grep -rn "def validate" --include="*.py" | grep -v test
find . -path "*/some_crate*" -exec grep "fn method" {} \;
```
**Instead**: Serena `find_symbol` or ast-grep `sg --lang rust -p 'trait CommandBuilder'`.

### 4. Building code to discover types
```bash
# WRONG — compiling just to read error messages for type info
cargo check 2>&1 | grep "expected"
tsc --noEmit 2>&1 | grep "Type '"
mypy src/ 2>&1 | grep "has type"
```
**Instead**: LSP `hover` on the expression — it shows the inferred type.

### 5. Reading entire files for one signature
```bash
# WRONG — loading 500 lines to find one function
cat src/lib.rs | grep -A 20 "fn new"
```
**Instead**: LSP `documentSymbol` to list all symbols, then `hover` on the one you need.
Or Serena `find_symbol(name="new", include_body=True)`.

## When Tools Aren't Available

Not every project has all tools active:

| Situation | Fallback |
|---|---|
| No LSP running | Serena `find_symbol(include_body=True)` for local code |
| Serena not activated | LSP `findReferences` + `documentSymbol` |
| Neither LSP nor Serena | ast-grep for structure, Grep for text (last resort) |
| Context7 doesn't have the library | octocode search → WebFetch raw source |
| External crate, no MCP available | `WebSearch` for official docs (via /fetch skill) |

The hierarchy is: **LSP > Serena > ast-grep > Grep**. Only fall to the next level
when the better tool genuinely isn't available — not because it's easier to type `grep`.

## Why This Skill Is NOT Forked

Unlike `/make` or `/fetch`, this skill runs inline — not in a subagent. Two reasons:

1. **LSP and Serena only work in the foreground context.** Forking would cut off
   the two most powerful tools (hover, find_symbol, findReferences).
2. **Routing is cheap.** This skill's output is a decision ("use LSP hover"), not
   verbose data. There's nothing to isolate from the context window.

The tools this skill routes TO may fork on their own (e.g., `/fetch` forks for
Context7/octocode lookups). That's fine — the routing decision stays inline,
the heavy fetching forks as needed.

## Rules

- Route FIRST, execute SECOND — decide which tool before running anything
- One lookup per question — don't chain 3 tools when one gives the answer
- External deps are NEVER solved by grepping local caches
- If LSP is running, `hover` answers 80% of type questions in one call
- If you need the skill that each tool delegates to, invoke it: /trace, /serena, /lsp, /fetch
