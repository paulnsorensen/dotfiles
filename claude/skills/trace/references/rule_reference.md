# ast-grep Rule Reference

Condensed from the official ast-grep documentation. For full details, see
https://ast-grep.github.io/llms-full.txt

## Rule categories

| Category | Purpose | Examples |
|---|---|---|
| **Atomic** | Match node properties | `pattern`, `kind`, `regex`, `nthChild` |
| **Relational** | Match by position in tree | `inside`, `has`, `precedes`, `follows` |
| **Composite** | Combine rules with logic | `all`, `any`, `not`, `matches` |

All fields in a rule object are optional but at least one "positive" key must
be present. Fields within the same rule object are implicitly ANDed.

## Atomic rules

### pattern

Match code by structure. String or object form.

```yaml
# String: direct pattern
pattern: console.log($ARG)

# Object: with context for ambiguous patterns
pattern:
  selector: field_definition
  context: class { $F }

# Object: with strictness
pattern:
  context: foo($BAR)
  strictness: relaxed  # cst | smart | ast | relaxed | signature
```

### kind

Match AST node by tree-sitter node type name.

```yaml
kind: call_expression        # JavaScript/TypeScript
kind: function_declaration   # JavaScript/TypeScript
kind: class_definition       # Python
kind: function_definition    # Python
```

Use `--debug-query=ast` to discover correct kind values for your language.

### regex

Match node text by Rust regex. Not "positive" — must combine with other rules.

```yaml
regex: ^[a-z]+$
```

### nthChild

Match by position in parent's children (1-based, named nodes only by default).

```yaml
nthChild: 1          # First child
nthChild: "2n+1"     # Odd-numbered children (An+B formula)
nthChild:
  position: 1
  reverse: true      # Count from end (last child)
  ofRule:             # Filter siblings before counting
    kind: required_parameter
```

## Relational rules

### inside

Target must be descendant of matching node.

```yaml
inside:
  pattern: class $C { $$$ }
  stopBy: end
```

### has

Target must have descendant matching the rule.

```yaml
has:
  pattern: await $EXPR
  stopBy: end
```

### precedes / follows

Target must appear before/after matching node textually.

```yaml
precedes:
  pattern: return $VAL
follows:
  pattern: import $M from '$P'
```

### stopBy (critical)

Controls how far relational rules search.

| Value | Behavior |
|---|---|
| `"neighbor"` (default) | Stop at first non-matching surrounding node |
| `"end"` | Search to end of direction (root/leaf) |
| `{rule}` | Stop when surrounding node matches the rule |

**Best practice**: Always use `stopBy: end` unless you have a specific reason
not to. Without it, searches terminate too early.

### field

Restrict relational match to a specific child field (only `inside` and `has`).

```yaml
has:
  field: operator
  pattern: $$OP
```

## Composite rules

### all (AND)

All sub-rules must match. Order is guaranteed — important for metavariable reuse.

```yaml
all:
  - kind: call_expression
  - pattern: console.log($ARG)
```

### any (OR)

At least one sub-rule must match.

```yaml
any:
  - pattern: console.log($$$)
  - pattern: console.warn($$$)
  - pattern: console.error($$$)
```

### not (negation)

Sub-rule must NOT match.

```yaml
not:
  pattern: console.log($ARG)
```

### matches (reuse)

Reference a utility rule by ID. Enables rule reuse and recursion.

```yaml
matches: my-utility-rule-id
```

## Metavariables

| Syntax | Captures | Example |
|---|---|---|
| `$VAR` | Single named node | `console.log($MSG)` |
| `$$VAR` | Single unnamed node (operator, punctuation) | `$A $$OP $B` |
| `$$$VAR` | Zero or more nodes (non-greedy) | `f($$$ARGS)` |
| `$_VAR` | Non-capturing (different content OK) | `$_F($_F)` matches `test(a)` |

**Naming rules**: `$UPPER_SNAKE` only. `$lowercase` and `$KEBAB-CASE` won't work.

**Reuse semantics**: Same-named metavariable must match identical content.
`$A == $A` matches `x == x` but not `x == y`.

**Limitation**: Metavariable must be the entire content of an AST node.
`obj.on$EVENT` and `"Hello $WORLD"` won't work.

## Common patterns by language

### Python
```yaml
# Classes inheriting from ABC
pattern: 'class $NAME(ABC): $$$BODY'

# Decorated functions
pattern: '@$DEC\ndef $NAME($$$ARGS): $$$BODY'

# Async with await
rule:
  pattern: 'async def $NAME($$$ARGS): $$$BODY'
  has:
    pattern: await $EXPR
    stopBy: end
```

### TypeScript / JavaScript
```yaml
# Interface implementations
pattern: 'class $NAME implements $IFACE { $$$BODY }'

# Arrow functions
pattern: 'const $NAME = ($$$ARGS) => $BODY'

# React hooks
pattern: 'const [$STATE, $SETTER] = useState($INIT)'

# Console methods (any)
any:
  - pattern: console.log($$$)
  - pattern: console.warn($$$)
  - pattern: console.error($$$)
```

### Go
```yaml
# Interface definitions
pattern: 'type $NAME interface { $$$METHODS }'

# Error handling check
rule:
  pattern: '$VAR, err := $CALL'
  not:
    has:
      pattern: 'if err != nil'
      stopBy: end

# Struct definitions
pattern: 'type $NAME struct { $$$FIELDS }'
```

### Rust
```yaml
# Trait implementations
pattern: 'impl $TRAIT for $TYPE { $$$BODY }'

# Unwrap calls (potential panics)
pattern: '$EXPR.unwrap()'

# Async functions
pattern: 'async fn $NAME($$$ARGS) -> $RET { $$$BODY }'
```

## Troubleshooting

1. **No matches**: Simplify the rule, remove sub-rules one at a time
2. **Wrong node kind**: Use `--debug-query=ast` to inspect actual AST structure
3. **Relational rule too narrow**: Add `stopBy: end`
4. **Metavariable not captured**: Ensure it's the only content in its AST node
5. **Shell eats `$`**: Escape as `\$` in double-quoted strings
6. **Pattern too complex**: Break into smaller sub-rules using `all`
