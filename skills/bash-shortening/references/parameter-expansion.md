# Parameter expansion

Examples 8-15 from the source article. Parameter expansion is the highest
ROI shortening technique: every `$(...)` you replace eliminates a
`fork()` + `exec()` pair, so it's both shorter *and* faster.

The general form is `${var<modifier>}`. Modifiers chain (carefully — see
anti-patterns).

## Example 8 — Default value (`:-`)

```bash
# Before
if [ -z "$ENVIRONMENT" ]; then
  ENVIRONMENT="development"
fi

# After
ENVIRONMENT=${ENVIRONMENT:-development}
```

`${var:-default}` evaluates to `$var` if set and non-empty, else `default`.
The variable itself is *not* assigned — it's just the expansion value.

To **also assign** (so subsequent uses see the default), use `:=`:

```bash
: ${ENVIRONMENT:=development}     # the leading `:` is the no-op command
```

## Example 9 — Alternative value (`:+`)

```bash
# Before
if [ -n "$ENVIRONMENT" ]; then
  ENV_NAME=$ENVIRONMENT
else
  ENV_NAME="unknown"
fi

# After
ENV_NAME=${ENVIRONMENT:+$ENVIRONMENT}
ENV_NAME=${ENV_NAME:-unknown}
```

`${var:+value}` evaluates to `value` if `$var` is set and non-empty, else
empty. Useful for conditionally adding flags:

```bash
SSH_OPTS=${VERBOSE:+-v}             # add -v only if VERBOSE is set
ssh $SSH_OPTS user@host
```

## Example 10 — Substring extraction

```bash
# Before
FIRST_FIVE=$(echo "$STRING" | cut -c1-5)

# After
FIRST_FIVE=${STRING:0:5}
```

Form: `${var:offset:length}`. Offset is 0-indexed. Both can be negative
(with a space before the minus to avoid confusion with `:-`):

```bash
LAST_THREE=${STRING: -3}             # last 3 chars
MIDDLE=${STRING:5: -2}               # from index 5, drop last 2
```

## Example 11 — Filename from path (`##`)

```bash
# Before
FILENAME=$(basename "$FULLPATH")

# After
FILENAME=${FULLPATH##*/}
```

`##` strips the longest match of the pattern from the **start**. Pattern
`*/` greedily eats up to and including the last `/`.

**Edge case:** if `$FULLPATH` carries a trailing slash (e.g. iterating
`for x in "$dir"/*/`), `basename` strips the slash and returns the leaf
name, but `${FULLPATH##*/}` treats the trailing `/` as the last separator
and yields an empty string. Hand-edit only when the path is known to be
normalized — the rewriter does **not** auto-apply this rewrite for that
reason.

For extension stripping (the `basename "$f" .ext` case):

```bash
NAME=${FULLPATH##*/}                  # strip dirs
STEM=${NAME%.*}                       # strip extension
```

## Example 12 — Directory from path (`%`)

```bash
# Before
DIRECTORY=$(dirname "$FULLPATH")

# After
DIRECTORY=${FULLPATH%/*}
```

`%` strips the shortest match of the pattern from the **end**. `%%` is the
greedy version (longest match). Memory aid: `#` is left of `$` on the
keyboard (start of string), `%` is to the right (end of string).

**Edge cases:** (1) `${FULLPATH%/*}` returns the original path unchanged
when there's no `/` (i.e. `myfile.txt` stays `myfile.txt`, not `.`); real
`dirname` returns `.`. (2) For trailing-slash paths like `/tmp/foo/`,
`dirname` returns `/tmp` but `${FULLPATH%/*}` returns `/tmp/foo`. The
rewriter does **not** auto-apply this rewrite for those reasons — use
the real tool when the path's shape is unknown.

## Example 13 — Replace first match

```bash
# Before
NEW_STRING=$(echo "$STRING" | sed 's/old/new/')

# After
NEW_STRING=${STRING/old/new}
```

## Example 14 — Replace all matches

```bash
# Before
NEW_STRING=$(echo "$STRING" | sed 's/old/new/g')

# After
NEW_STRING=${STRING//old/new}
```

Bonus forms:

```bash
${STRING/#prefix/new}        # replace only if at start (anchored)
${STRING/%suffix/new}        # replace only if at end
${STRING//old/}              # delete all occurrences (empty replacement)
```

The pattern is glob-style (`*`, `?`, `[abc]`), not regex. For real regex,
fall back to `sed` or `[[ $s =~ regex ]]` with `${BASH_REMATCH[@]}`.

## Example 15 — String length

```bash
# Before
LENGTH=$(echo -n "$STRING" | wc -c)

# After
LENGTH=${#STRING}
```

Same form for arrays (counts elements):

```bash
arr=(a b c)
echo ${#arr[@]}              # 3
```

**Caveat:** `${#str}` counts *characters*, not *bytes*. With multi-byte
UTF-8 input and `LANG=C`, you'll get bytes. With a UTF-8 locale, you'll
get codepoints. If you need actual byte length, `LANG=C wc -c` is the
honest tool.

## Cheatsheet

```text
${var}              value of var
${var:-default}     value of var, or "default" if unset/empty
${var:=default}     ditto, AND assign default to var
${var:+alt}         "alt" if var is set/non-empty, else empty
${var:?msg}         value, or print "msg" and exit if unset/empty
${var:offset}       substring from offset to end
${var:offset:len}   substring of length len from offset
${#var}             length in characters
${var#pat}          strip shortest pat from start
${var##pat}         strip longest  pat from start
${var%pat}          strip shortest pat from end
${var%%pat}         strip longest  pat from end
${var/pat/repl}     replace first match of pat with repl
${var//pat/repl}    replace ALL matches
${var/#pat/repl}    replace only if pat is at start
${var/%pat/repl}    replace only if pat is at end
${var^^}            uppercase (bash 4+)
${var,,}            lowercase (bash 4+)
${var^}             capitalize first character
```

## Common mistakes

- **Forgetting the colon.** `${var-default}` (no colon) only triggers on
  *unset*, not on *empty*. With colon (`${var:-default}`) covers both.
  When the user passes `--flag=""`, you almost always want the colon form.
- **Quoting.** All these expansions need to live inside double quotes when
  the result might contain spaces: `cp "${SRC%/*}/$NAME" /dest/`. Drop the
  quotes and word-splitting strikes.
- **Pattern is glob, not regex.** `${url//https?/x}` does not work — `?`
  is "match one char" in glob, but the `?` after `s` makes it literal at
  the wrong spot. Test patterns with a quick `echo "${var//pat/X}"`.
