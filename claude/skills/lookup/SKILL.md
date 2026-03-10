---
name: lookup
description: >
  Code intelligence router — decides which tool to use when you need to understand
  a symbol, type, API, or code relationship. Prevents wasteful cargo doc + grep
  chains, grepping node_modules or cargo registry, and other brute-force lookup
  anti-patterns. Use this skill BEFORE reaching for bash when the question is
  "what does X do?", "what's the signature of Y?", "who calls Z?", or "how do I
  use this API?". Routes to the right tool: LSP for types, Serena for cross-refs,
  ast-grep for structural patterns, Context7 for external docs, octocode for
  GitHub code search. If you catch yourself writing cargo doc, grepping registry
  caches, or chaining find+grep for a method signature — stop and use this instead.
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
| Who implements this trait/interface? | **ast-grep** `sg -p 'impl $T for $S'` | **octocode** `search_code` |
| All usages of a type | **Serena** `find_referencing_symbols` | **octocode** `search_code` |
| Method list on a struct/class | **LSP** `documentSymbol` | **Context7** `query-docs` |
| What does this function do? | **LSP** `hover` + **Read** the body | **Context7** or **WebFetch** raw source |
| Find structural patterns | **ast-grep** `sg --lang X -p 'pattern'` | N/A — use octocode text search |
| Error type / return type | **LSP** `hover` | **Context7** `query-docs` |

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

**ast-grep** (zero config, via /trace skill):
- `sg --lang X -p 'pattern'` — structural pattern matching
- Best for: "find all classes that extend Z", "which functions have >4 params"
- Works on AST shape, not text — won't false-match comments or strings

**Context7** (MCP, for external libraries):
- `resolve-library-id` → `query-docs` — version-specific docs + examples
- Best for: "what's the API of portable-pty?", "how does serde derive work?"

**octocode** (MCP, GitHub code search):
- `search_code` — find implementations across public repos
- Best for: "how do people use this API?", "show me examples of X"

## Anti-Patterns — NEVER Do These

These are the brute-force patterns this skill exists to prevent:

### 1. cargo doc + grep
```bash
# WRONG — generates docs just to grep them
cargo doc -p some-crate --no-deps 2>&1
grep -r "fn method_name" target/doc/
```
**Instead**: Context7 `query-docs` for the crate, or octocode to search the crate's repo.

### 2. Grepping dependency caches
```bash
# WRONG — reading vendored source for a signature
grep -r "fn env" ~/.cargo/registry/src/*/portable-pty-*/
grep -r "interface Props" node_modules/react/
find . -path "*/some_crate*" -exec grep "fn method" {} \;
```
**Instead**: LSP `hover` on the symbol where you use it, or Context7 for the docs.

### 3. Multi-step find + grep chains
```bash
# WRONG — O(n) scanning for what's an O(1) lookup
find . -name "*.rs" | xargs grep "trait CommandBuilder"
grep -rn "def validate" --include="*.py" | grep -v test
```
**Instead**: Serena `find_symbol` or ast-grep `sg --lang rust -p 'trait CommandBuilder'`.

### 4. Building code to discover types
```bash
# WRONG — compiling just to read error messages for type info
cargo check 2>&1 | grep "expected"
tsc --noEmit 2>&1 | grep "Type '"
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

## Rules

- Route FIRST, execute SECOND — decide which tool before running anything
- One lookup per question — don't chain 3 tools when one gives the answer
- External deps are NEVER solved by grepping local caches
- If LSP is running, `hover` answers 80% of type questions in one call
- If you need the skill that each tool delegates to, invoke it: /trace, /serena, /lsp, /fetch
