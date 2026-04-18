---
name: lookup
model: haiku
description: >
  Code intelligence router — decides which tool to use when you need to understand
  a symbol, type, API, or code relationship. Language-agnostic: works for Rust,
  Python, TypeScript, Go, Ruby, Java, and any language with LSP support. Prevents
  wasteful brute-force lookup anti-patterns: cargo doc + grep, grepping dependency
  caches (node_modules, site-packages, .cargo/registry, go/pkg/mod, .m2),
  go doc + grep, python help() + grep, and multi-step find chains. Use this skill
  BEFORE reaching for bash when the question is "what does X do?", "what's the
  signature of Y?", "who calls Z?", or "how do I use this API?". Routes to the
  right tool: LSP for types and cross-refs, ast-grep for structural
  patterns, Context7 for external docs, octocode for GitHub code search. If you
  catch yourself about to grep a dependency cache or generate docs just to search
  them — stop and use this instead.
---

# lookup

Code intelligence routing. Ask the right tool, not bash.

When you need to understand a symbol, type, or API, your instinct might be to
grep for it, run `cargo doc`, or read files in `node_modules`. Don't. You have
four purpose-built tools that are faster, cheaper, and don't pollute your context.
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
| Who calls this function? | **LSP** `findReferences` | **octocode** `search_code` |
| Who implements this trait/interface? | **tilth_search** `kind: symbol` | **octocode** `search_code` |
| All usages of a type | **LSP** `findReferences` | **octocode** `search_code` |
| Method list on a struct/class | **LSP** `documentSymbol` | **Context7** `query-docs` |
| What does this function do? | **LSP** `hover` + **tilth_read** the body | **Context7** or **WebFetch** raw source |
| Find structural patterns | **tilth_search** `kind: symbol` or `kind: regex` | N/A — use octocode text search |
| Error type / return type | **LSP** `hover` | **Context7** `query-docs` |
| Find files by name/pattern | **tilth_files** (glob, gitignore-aware) | N/A |
| Find files by content | **tilth_search** `kind: content` or `kind: regex` | **octocode** `search_code` |
| List directory contents | **tilth_files** `pattern: *` | **octocode** `view_repo_structure` |

### Quick reference by tool

**LSP** (built-in tool, zero setup):

- `hover` — type signature, docs, return type
- `goToDefinition` — jump to where it's defined
- `findReferences` — all usages in the project
- `documentSymbol` — list all symbols in a file
- Works on: .rs, .py, .ts, .go, .sh, .yaml, .rb (all 7 LSP plugins)

**tilth_search** (MCP, AST-aware — zero config):

- `kind: symbol` — finds definitions and usages by symbol name (AST-based, not text)
- `kind: content` — literal text search across files
- `kind: regex` — PCRE2 regex search
- `kind: callers` — all call sites of a symbol
- `expand: N` — inline top N match source bodies directly in results
- Best for: "what implements X?", "who calls Y?", "find all uses of Z"

**tilth_files** (MCP, file discovery):

- `tilth_files(pattern: "**/*.ts")` — glob with token estimates, gitignore-aware
- **NEVER use `find`** — use tilth_files instead. `find` is blocked by hook.

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

**Instead**: LSP `findReferences` or ast-grep `sg --lang rust -p 'trait CommandBuilder'`.

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
Or LSP `goToDefinition` on the symbol.

## When Tools Aren't Available

Not every project has all tools active:

| Situation | Fallback |
|---|---|
| No LSP running | tilth_search kind:symbol for structure, kind:content for text |
| Context7 doesn't have the library | octocode search → WebFetch raw source |
| External crate, no MCP available | `WebSearch` for official docs (via /fetch skill) |

The hierarchy is: **LSP > tilth_search > Grep**. Only fall to the next level
when the better tool genuinely isn't available — not because it's easier to type `grep`.

## Why This Skill Is NOT Forked

Unlike `/make` or `/fetch`, this skill runs inline — not in a subagent. Two reasons:

1. **LSP only works in the foreground context.** Forking would cut off
   the most powerful tool (hover, findReferences, goToDefinition).
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
- If you need the skill that each tool delegates to, invoke it: /lsp, /fetch

## Gotchas

- LSP servers start lazily — first `hover` or `goToDefinition` may fail, retry after a moment
- Context7 library ID resolution sometimes returns wrong package for ambiguous names — verify
- ast-grep patterns are language-specific — Rust `impl` blocks vs Go `func` declarations have different AST shapes
- Training data is often sufficient for well-known libraries — don't fetch docs for stdlib
