---
name: trace
allowed-tools: Bash(sg:*), Bash(ast-grep:*)
model: haiku
description: >
  Use ast-grep (sg) for structural code parsing and architectural mapping.
  Invoke this skill when asked to: audit SOLID principles, find which classes
  implement a port or interface, locate repository or adapter boundaries, map
  hexagonal architecture layers, enumerate method signatures across a codebase,
  or answer structural questions that text search cannot. Prefer this over
  rg/grep whenever the question is about code *shape* ("what implements X?",
  "which adapters call Y?") rather than text patterns. Especially valuable for
  hexagonal architecture audits and dependency direction enforcement.
  IMPORTANT: this skill operates in a strict no-file-read environment — every
  answer must come from sg output alone.
---

# trace

Structural code analysis using ast-grep (`sg`). Finds symbols, patterns, and
architectural boundaries by parsing the AST — not by text-matching raw bytes.

**Zero config required.** Works on any codebase without `sg init` or `sgconfig.yml`.
Config files are only for rule authoring (shared lint rules, test infrastructure).

## Constraints

- **Never read full files.** Do not use `cat`, `less`, `head`, or `tail` in
  Bash, and do not use the Read tool. Every insight must come from `sg` output.
- Bash is the only tool for execution — run `sg` commands and surface the
  results.

## When to use trace vs. other tools

| Question shape | Tool |
|---|---|
| "Find all X that contain Y" (structural) | **trace** (ast-grep) |
| "What implements interface Z?" (shape) | **trace** (ast-grep) |
| "Who calls function foo?" (semantic) | **serena** (LSP-backed) |
| "Go to definition of bar" (navigation) | **serena** (LSP-backed) |
| "Find text pattern in files" | **scout** (rg) |
| "Type of variable X?" (inference) | LSP server (via `/lsp`) |

## Core invocations

### Simple pattern search (run)

```bash
sg --lang <language> -p '<pattern>' [path]
```

For quick, single-pattern matches. Add `--json` for structured output.

### Complex structural search (scan --inline-rules)

```bash
sg scan --inline-rules "id: my-rule
language: <language>
rule:
  <rule-definition>" [path]
```

For relational rules (inside/has), composite logic (all/any/not), and
multi-condition queries. **Always use `stopBy: end`** in relational rules:

```yaml
has:
  pattern: await $EXPR
  stopBy: end
```

Without `stopBy: end`, the search stops at the first non-matching node instead
of traversing the full subtree.

### AST inspection (debug)

```bash
sg run --pattern '<code>' --lang <language> --debug-query=ast
```

Use to discover correct `kind` values for node types (e.g., `function_declaration`,
`call_expression`). Available formats: `ast`, `cst`, `pattern`.

## Supported languages

`python`, `typescript`, `javascript`, `tsx`, `go`, `rust`, `java`, `ruby`,
`c`, `cpp`, `css`, `html`, `php`, `swift`, `kotlin`, `scala`, `lua`, `bash`,
and ~20 more.

## Metavariables

| Syntax | Matches | Example |
|---|---|---|
| `$NAME` | Exactly one AST node | `console.log($ARG)` |
| `$$$NAME` | Zero or more nodes | `function $F($$$ARGS) { $$$BODY }` |
| `$` | Throwaway single-node wildcard | `if ($) { $$$BODY }` |
| `$$OP` | Single unnamed node (operator, punctuation) | Binary operator capture |

**Reuse**: `$A == $A` matches `x == x` but NOT `x == y`.
**Naming**: Must be `$UPPER_SNAKE` — `$lowercase` won't be detected.

## Shell escaping

In `--inline-rules` strings, escape `$` as `\$` to prevent shell interpolation:

```bash
sg scan --inline-rules "id: test
language: javascript
rule:
  pattern: console.log(\$ARG)" .
```

Or use single quotes for the entire argument when possible.

## Pattern examples

### Classes with base classes (Python)
```bash
sg --lang python -p 'class $A($B): $$$BODY'
```

### Method definitions (Python)
```bash
sg --lang python -p 'def $METHOD(self, $$$ARGS): $$$BODY'
```

### Function calls on objects (TypeScript)
```bash
sg --lang typescript -p '$OBJ.save($$$ARGS)'
```

### Async handlers (Python)
```bash
sg --lang python -p 'async def $NAME($$$ARGS): $$$BODY'
```

### isinstance checks (Python)
```bash
sg --lang python -p 'isinstance($OBJ, $TYPE)'
```

### Inheritance — TypeScript
```bash
sg --lang typescript -p 'class $NAME extends $BASE { $$$BODY }'
```

### Interface implementation — TypeScript
```bash
sg --lang typescript -p 'class $NAME implements $IFACE { $$$BODY }'
```

### Decorator matching — Python
```bash
sg --lang python -p '@$DECORATOR
def $NAME($$$ARGS): $$$BODY'
```

### Import audit — scoped
```bash
sg --lang python -p 'from $MODULE import $NAME' -r src/adapters/
```

## Complex queries (YAML rules)

### Async functions without try-catch (JavaScript)
```bash
sg scan --inline-rules "id: async-no-trycatch
language: javascript
rule:
  all:
    - kind: function_declaration
    - has:
        pattern: await \$EXPR
        stopBy: end
    - not:
        has:
          pattern: try { \$\$\$ } catch (\$E) { \$\$\$ }
          stopBy: end" .
```

### console.log inside class methods (JavaScript)
```bash
sg scan --inline-rules "id: console-in-class
language: javascript
rule:
  pattern: console.log(\$\$\$)
  inside:
    kind: method_definition
    stopBy: end" .
```

### Functions with too many parameters (TypeScript)
```bash
sg scan --inline-rules "id: too-many-params
language: typescript
rule:
  kind: formal_parameters
  has:
    nthChild:
      position: 5
      ofRule:
        kind: required_parameter
  stopBy: end" .
```

### Empty except blocks (Python)
```bash
sg --lang python -p 'except $E: pass'
```

## Workflow for complex searches

1. **Understand** — What structural pattern? Which language?
2. **Inspect AST** — `--debug-query=ast` to find correct `kind` values
3. **Start simple** — Try `sg --lang X -p 'pattern'` first
4. **Compose** — If simple pattern isn't enough, use `scan --inline-rules`
   with relational/composite rules
5. **Scope** — Restrict with path argument or `-r <dir>`

## Output format

Return **only** a concise bulleted list. Each bullet must contain:

- The exact file path (relative to repo root)
- The line number
- The matched snippet (trimmed to the first meaningful line)

**Example:**
```
- src/adapters/postgres_user_repo.py:14 — class PostgresUserRepo(UserRepository):
- src/adapters/redis_cache.py:8 — class RedisCache(CachePort):
```

Never include file contents, explanations, or analysis — the orchestrator
decides what to read next based on this list.

## Hexagonal architecture audit workflow

1. Find all ports:
   ```bash
   sg --lang python -p 'class $PORT(ABC): $$$BODY'
   sg --lang python -p 'class $PORT(Protocol): $$$BODY'
   ```

2. Find all implementations:
   ```bash
   sg --lang python -p 'class $ADAPTER($PORT): $$$BODY'
   ```

3. Verify adapters don't bleed into domain:
   ```bash
   sg --lang python -p 'from $MODULE import $NAME' -r src/domains/
   ```

4. Report findings as bulleted file:line pairs — let the caller decide what
   warrants deeper inspection.

## Rule reference

For comprehensive rule syntax (atomic, relational, composite rules, metavariable
constraints, transforms), see `references/rule_reference.md`.
