# Command substitution and pipelines

Examples 3-7 from the source article. The unifying idea: every temp file
and every intermediate variable that's used only once is a candidate for
elimination. Pipelines flow data without touching disk.

## Example 3 — Inline command substitution

```bash
# Before
DATE=$(date +%Y-%m-%d)
echo "Today is $DATE"

# After
echo "Today is $(date +%Y-%m-%d)"
```

**When to keep the variable:** if the value is used 2+ times, or if it's
expensive to compute (a network call, a long pipeline). Single-use values
inline cleanly.

## Example 4 — Avoid duplicate computation

```bash
# Before — runs grep twice
USER_HOME=$(grep "^$USERNAME:" /etc/passwd | cut -d: -f6)
USER_SHELL=$(grep "^$USERNAME:" /etc/passwd | cut -d: -f7)

# After — single grep, two extracts
USER_INFO=$(grep "^$USERNAME:" /etc/passwd)
USER_HOME=$(echo "$USER_INFO" | cut -d: -f6)
USER_SHELL=$(echo "$USER_INFO" | cut -d: -f7)
```

The article reports a 45s → 8s improvement on a large /etc/passwd. The
generalization: when you're running the same expensive command and slicing
its output different ways, capture once.

**Even better in modern bash:** read into an array.

```bash
IFS=: read -r _ _ _ _ _ USER_HOME USER_SHELL _ < <(grep "^$USERNAME:" /etc/passwd)
```

That's *one* process and *one* parse. See `process-substitution.md` for
the `< <(...)` syntax and `advanced.md` for `IFS=` patterns.

## Example 5 — Pipeline instead of temp file

```bash
# Before
grep "ERROR" /var/log/app.log > /tmp/errors.log
cat /tmp/errors.log | wc -l
rm /tmp/errors.log

# After
grep "ERROR" /var/log/app.log | wc -l
```

Three operations collapse to one. No cleanup, no race condition, no risk
of leaving a stale `/tmp/errors.log` if the script crashes between
write and `rm`.

## Example 6 — `xargs` instead of read-loop with temp file

> **Source divergence.** The article shows
> `find /var/log -name "*.log" | xargs gzip`. That breaks on filenames
> with spaces, tabs, newlines, or quotes — and a `/var/log` with a
> rotated file like `app log.gz` is enough to send `gzip: app: No such
> file` errors flying. The version below preserves the lesson
> ("replace read-loop + temp file with `xargs`") with the safety
> flags that make it production-grade.

```bash
# Before
find /var/log -name "*.log" > /tmp/logs.txt
while read -r logfile; do
  gzip "$logfile"
done < /tmp/logs.txt
rm /tmp/logs.txt

# After — null-delimited, empty-safe
find /var/log -name "*.log" -print0 | xargs -0 -r gzip
```

The three flags carry the safety guarantees:

- `-print0` makes `find` emit null-terminated paths (no whitespace
  ambiguity).
- `xargs -0` consumes null-terminated input.
- `xargs -r` skips the invocation entirely when input is empty
  (otherwise `gzip` runs with zero args and errors).

For one-arg-per-call (when the command can't accept many): `xargs -0 -n1`.
For parallelism: `xargs -0 -P 4` runs up to 4 in parallel.

## Example 7 — Chain filters in a pipeline

```bash
# Before
grep "ERROR" /var/log/app.log > /tmp/errors.log
grep "database" /tmp/errors.log
rm /tmp/errors.log

# After
grep "ERROR" /var/log/app.log | grep "database"
```

Or, if the patterns are independent rather than narrowing:

```bash
grep -E "ERROR|WARN" /var/log/app.log
```

For 3+ stages, consider `awk` for a single-pass filter:

```bash
awk '/ERROR/ && /database/ {print}' /var/log/app.log
```

## When to keep a temp file anyway

Pipelines are not always the answer:

- **The output is consumed by 2+ later commands.** Capturing to a variable
  works for small data; for large data (logs, dumps), a temp file
  outperforms a multi-megabyte variable in memory.
- **You need random access.** Pipelines are streams; you can't seek back.
- **The producer and consumer have very different runtimes.** Pipelines
  buffer in the kernel pipe (typically 64KB on Linux); a slow consumer
  blocks a fast producer. A temp file decouples them.

When you do use a temp file, use `mktemp` and `trap` for cleanup:

```bash
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
# ... work with "$TMP" ...
```

The `trap ... EXIT` runs the cleanup whether the script succeeds, fails,
or is killed — eliminating the leaked-temp-file class of bug entirely.
