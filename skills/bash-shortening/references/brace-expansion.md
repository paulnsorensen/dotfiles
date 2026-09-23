# Brace expansion and sequence expressions

Examples 21-26 from the source article. Brace expansion happens *before*
any other expansion, so it generates the literal command line bash will
then run. Use `echo {a,b,c}` to preview without executing — that's the
single best way to debug brace patterns.

## Example 21 — Comma list for related paths

```bash
# Before
mkdir -p /data/app/config
mkdir -p /data/app/logs
mkdir -p /data/app/tmp

# After
mkdir -p /data/app/{config,logs,tmp}
```

The shell expands to `mkdir -p /data/app/config /data/app/logs /data/app/tmp`
before executing — same command, fewer keystrokes, no chance of typos in
the prefix.

**Spaces inside the braces break the expansion** — `{config, logs}` becomes
two literal arguments `{config,` and `logs}`. Always close-pack.

## Example 22 — Nested brace expansion

```bash
# Before
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
cp /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak

# After
cp /etc/nginx/{nginx.conf,sites-available/default}{,.bak}
```

The trailing `{,.bak}` expands to `""` and `".bak"` — the empty alternative
is what makes "make a backup of each" idiomatic. Reads as:

```text
{nginx.conf, sites-available/default} × {"", ".bak"}
= nginx.conf nginx.conf.bak sites-available/default sites-available/default.bak
```

`cp` consumes them in source/dest pairs.

**Always preview first** with `echo`:

```bash
echo cp /etc/nginx/{nginx.conf,sites-available/default}{,.bak}
```

This is non-negotiable for nested expansions — one wrong brace and you
shuffle source and destination.

## Example 23 — Numeric sequence

```bash
# Before
for i in 1 2 3 4 5; do
  echo "Processing item $i"
done

# After
for i in {1..5}; do
  echo "Processing item $i"
done
```

For very large ranges (`{1..1000000}`), brace expansion *materializes the
whole list into memory before the loop starts*. Switch to C-style for:

```bash
for ((i=1; i<=1000000; i++)); do
  echo "$i"
done
```

C-style `for` doesn't pre-materialize and is the right tool past ~10K.

## Example 24 — Character sequence

```bash
# Before
for c in a b c d e; do
  echo "Processing $c"
done

# After
for c in {a..e}; do
  echo "Processing $c"
done
```

Works for `{A..Z}`, `{a..z}`, and ranges that span case boundaries (gives
all the ASCII-ordered chars, including the punctuation between `Z` and
`a` — usually not what you want).

## Example 25 — Sequence with step

```bash
# Before
for i in 2 4 6 8 10; do
  echo "Even $i"
done

# After
for i in {2..10..2}; do
  echo "Even $i"
done
```

Step works for both numeric and character sequences. Negative step
(reverse order):

```bash
for i in {10..1..-1}; do echo "$i"; done   # countdown
for i in {10..1};      do echo "$i"; done  # also descending — bash infers
```

## Example 26 — Zero-padded sequences

```bash
# Before
for i in 01 02 03 04 05 06 07 08 09 10; do
  echo "Processing $i"
done

# After
for i in {01..10}; do
  echo "Processing $i"
done
```

Padding is determined by the *first* element. `{01..100}` produces
`001 002 ... 099 100` — three digits throughout. Useful for filename
generation (`backup-{01..30}.tar.gz`) where lexical sort order matches
numeric order.

## Combinations worth knowing

```bash
# Cartesian product of two lists
touch file_{a,b,c}_{1,2,3}.txt
# → file_a_1.txt file_a_2.txt file_a_3.txt file_b_1.txt ...

# Range + suffix
echo backup-{01..05}.tar.gz
# → backup-01.tar.gz backup-02.tar.gz ... backup-05.tar.gz

# Stepped letter range (every other)
echo {a..z..2}
# → a c e g i k m o q s u w y
```

## Precedence trap

Brace expansion runs *before* variable expansion. This does **not** work:

```bash
START=1; END=5
echo {$START..$END}        # prints literally: {1..5} — not 1 2 3 4 5
```

Workarounds:

```bash
seq $START $END                       # external tool, but reliable
eval echo {$START..$END}              # works, but eval is sharp — avoid
for ((i=START; i<=END; i++)); do echo "$i"; done   # native, safe
```

For dynamic ranges, `seq` or C-style `for` are the right answers.

## When brace expansion isn't worth it

- **One element.** `mkdir foo` beats `mkdir {foo}` (which expands to
  `mkdir foo` anyway, but obscures intent).
- **Variable-driven lists.** See the precedence trap above. Use arrays:
  `dirs=(a b c); mkdir "${dirs[@]}"`.
- **Cross-shell scripts.** Brace expansion is bash/zsh, *not* POSIX. If
  the shebang is `#!/bin/sh`, it doesn't work — even if it happens to
  work on systems where `/bin/sh` links to bash.
