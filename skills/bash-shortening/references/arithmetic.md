# Arithmetic and conditional testing

Examples 32-38 from the source article. `expr` is dead — bash has had
native integer arithmetic since version 2 (1996). Same for `[ ]`'s
clunky `-eq`/`-gt` operators when `[[ ]]` and `(( ))` are right there.

## Example 32 — `$(( ))` for arithmetic in a value context

```bash
# Before
RESULT=$(expr $NUM1 + $NUM2)

# After
RESULT=$((NUM1 + NUM2))
```

Inside `$(( ))` you don't need `$` for variable references. The whole
expression is in arithmetic context — strings are auto-converted to
integers (with `0` for non-numeric input, which can hide bugs).

Operators: `+ - * / % ** << >> & | ^ ~ ! && || == != < <= > >= = += -= ...`.
Same precedence as C.

## Example 33 — `(( ))` for arithmetic as a statement

```bash
# Before
COUNT=$(expr $COUNT + 1)

# After
((COUNT++))
```

Bare `(( ))` evaluates an arithmetic expression for its side effects and
exit status (nonzero result → exit 0; zero → exit 1, which is the bash
convention even though it inverts C semantics — a gotcha when chaining
with `&&`).

```bash
((COUNT++))         # post-increment
((--COUNT))         # pre-decrement
((COUNT += 5))      # compound assignment
((TOTAL = N1 + N2)) # assignment
```

**Pitfall with `set -e`:** `((counter++))` exits with status 1 when
`counter` was 0 (the *previous* value is the result of post-increment, not
the new one). Under `set -e`, that kills your script. Workarounds:

```bash
((counter++)) || true                  # explicitly accept exit 1
counter=$((counter + 1))               # always exits 0
((counter+=1))                         # also fine — result is the new value
```

This is the single most common `set -e` + arithmetic foot-gun.

## Example 34 — Compound arithmetic

```bash
# Before
TOTAL=$(expr $PRICE \* $QUANTITY)
TOTAL=$(expr $TOTAL + $TAX)

# After
TOTAL=$(( (PRICE * QUANTITY) + TAX ))
```

`*` doesn't need escaping inside `$(( ))` (no glob expansion in arithmetic
context). Spaces around operators are optional but help readability.

## Example 35 — `(( ))` for comparisons

```bash
# Before
if [ $VALUE -gt 100 ]; then
  echo "Large value"
fi

# After
if ((VALUE > 100)); then
  echo "Large value"
fi
```

The mnemonic: `(( ))` for *math*; `[[ ]]` for *strings and files*; old
`[ ]` for nothing in modern bash unless you need POSIX.

## Example 36 — Conditional value assignment

> **Source divergence.** The article shows
> `STATUS=$((COUNT > 10 ? "high" : "low"))`. That does not work —
> bash arithmetic is integer-only and can't return string literals
> from a ternary. The version below preserves the lesson ("assign one
> of two values based on a condition, in one expression") with syntax
> that actually runs.

```bash
# Before — full if/else
if [ $COUNT -gt 10 ]; then
  STATUS="high"
else
  STATUS="low"
fi

# After — pre-set + arithmetic test (one expression, both branches)
STATUS=high; ((COUNT > 10)) || STATUS=low
```

Reads as: "default to `high`; if `COUNT > 10` is *false*, downgrade to
`low`." Two statements, but tightly coupled, and there's no `if`/`fi`
ceremony.

For three or more branches, reach for `case` — denser than nested
`if`/`elif` and easier to extend:

```bash
case $COUNT in
  0)         STATUS=zero ;;
  [1-9])     STATUS=low  ;;
  *)         STATUS=high ;;
esac
```

For integer-only assignments (where you really do want a number on each
side), bash arithmetic ternary works as expected:

```bash
MAX=$(( A > B ? A : B ))
SIGN=$(( N > 0 ? 1 : N < 0 ? -1 : 0 ))
```

The trick is recognizing when you need an integer (use `$(( ? : ))`)
versus a string (use `case` or short-circuit assignment).

## Example 37 — `[[ ]]` with logical operators

```bash
# Before
if [ $AGE -ge 18 ] && [ $HAS_ID -eq 1 ]; then
  echo "Access granted"
fi

# After
if [[ $AGE -ge 18 && $HAS_ID -eq 1 ]]; then
  echo "Access granted"
fi
```

`[[ ]]` is the modern test command. Differences from `[ ]`:

- `&&` and `||` work *inside* the brackets (with `[ ]` you needed two
  separate `[ ]` joined by shell `&&`).
- No word splitting on unquoted variables — `[[ $x = "" ]]` is safe even
  if `$x` is unset.
- `=~` for regex matching (with captures in `${BASH_REMATCH[@]}`).
- `<` and `>` do **lexical** comparison (need `((  ))` for numeric).

For numeric comparisons inside `[[ ]]`, you still need `-ge`, `-lt`, etc.
For pure numeric work, prefer `(( ))`:

```bash
if (( AGE >= 18 && HAS_ID == 1 )); then ...
```

That reads cleanly and uses the right operators.

## Example 38 — Compact file test + action

```bash
# Before
if [ -f "$FILE" ] && [ -r "$FILE" ]; then
  cat "$FILE"
fi

# After
[[ -f "$FILE" && -r "$FILE" ]] && cat "$FILE"
```

This is fine for *one* dependent action. Once there are two or more
actions inside the conditional, switch back to `if`/`fi` — chaining
`&& cat "$FILE" && echo "done"` makes the second action conditional on
the first's success, which is rarely what you mean.

## Operator quick reference

```text
== Numeric comparisons (use inside (( )) preferred over [[ ]] -eq) ==
(( a == b ))    equal
(( a != b ))    not equal
(( a <  b ))    less than
(( a <= b ))    less or equal
(( a >  b ))    greater than
(( a >= b ))    greater or equal

== String comparisons (inside [[ ]]) ==
[[ a == b ]]    equal       (single = also works; == is bash-preferred)
[[ a != b ]]    not equal
[[ a <  b ]]    lexically less than
[[ a >  b ]]    lexically greater than
[[ -z $a ]]     empty/unset
[[ -n $a ]]     non-empty
[[ a == pa* ]]  glob match
[[ a =~ ^p.+ ]] regex match (no quotes around the pattern in bash 3.2+)

== File tests (inside [[ ]] or [ ]) ==
-e PATH         exists
-f PATH         is a regular file
-d PATH         is a directory
-L PATH         is a symlink
-r PATH         readable
-w PATH         writable
-x PATH         executable
-s PATH         non-empty
PATH1 -nt PATH2 newer than (mtime)
PATH1 -ot PATH2 older than
```

## Common mistakes

- **Mixing `[ ]` and `[[ ]]`.** Pick one per file. Modern bash code uses
  `[[ ]]`. POSIX code stays with `[ ]`.
- **Forgetting that `(( ))` returns 1 on a zero result.** The `set -e`
  trap above. Use `||true` or `=$((expr))` form when scripting under `-e`.
- **Treating `[[ $a < $b ]]` as numeric.** It's lexical — `"10" < "9"`
  is true. Use `(( a < b ))` for numbers.
- **Quoting inside `[[ ]]` is optional but encouraged.** It's safe to
  drop, but quoting your variables consistently means readers don't have
  to track which constructs need quotes.
