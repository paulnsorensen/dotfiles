---
name: trace
allowed-tools: Bash(sg:*)
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

## Constraints

- **Never read full files.** Do not use `cat`, `less`, `head`, or `tail` in
  Bash, and do not use the Read tool. Every insight must come from `sg` output.
- Bash is the only tool for execution — run `sg` commands and surface the
  results.

## Core invocation

```bash
sg --lang <language> -p '<pattern>' [path]
```

`<language>`: `python`, `typescript`, `javascript`, `go`, `rust`, `java`, `ruby`, etc.

Metavariables:
- `$NAME` — matches a single AST node (identifier, expression, type)
- `$$$NAME` — matches zero or more nodes (body, arg list, sequence)
- Unnamed `$` is a throwaway single-node wildcard

Use `--json` for machine-readable output (file, line, column, text).
Use `-r <path>` to restrict search scope.

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

## Advanced patterns

### Inheritance — TypeScript
```bash
sg --lang typescript -p 'class $NAME extends $BASE { $$$BODY }'
```

### Interface implementation — TypeScript
```bash
sg --lang typescript -p 'class $NAME implements $IFACE { $$$BODY }'
```

### Multiple inheritance — Python
```bash
sg --lang python -p 'class $NAME($BASE1, $BASE2): $$$BODY'
```

### Decorator matching — Python
```bash
sg --lang python -p '@$DECORATOR
def $NAME($$$ARGS): $$$BODY'
```

### Class annotation — TypeScript
```bash
sg --lang typescript -p '@$ANNOTATION
class $NAME { $$$BODY }'
```

### Nested try/except in loop — Python
```bash
sg --lang python -p 'for $VAR in $ITER:
    try:
        $$$TRY_BODY
    except $E:
        $$$EXCEPT_BODY'
```

### Empty except blocks — Python
```bash
sg --lang python -p 'except $E: pass'
```

### Scoped import audit — Python
```bash
sg --lang python -p 'from $MODULE import $NAME' -r src/adapters/
```

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
