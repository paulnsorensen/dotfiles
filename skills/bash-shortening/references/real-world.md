# Real-world examples

Examples 39-45 from the source article. These combine multiple techniques
from the other references into the patterns you actually see in
production scripts.

## Example 39 — Config file parsing

```bash
# Before — read every line, branch on each
CONFIG_VALUE=""
while read -r line; do
  if [[ "$line" == *"KEY="* ]]; then
    CONFIG_VALUE=$(echo "$line" | cut -d= -f2)
  fi
done < config.ini

# After — let grep find the line
CONFIG_VALUE=$(grep "^KEY=" config.ini | cut -d= -f2)
```

Generalization: when scanning a file for *one* line, `grep` is faster
than a `while read` loop. The loop only wins when you need the *position*
of the line, or when you're processing every line anyway.

For multiple keys in one config, sourcing the file (when safe) is even
shorter:

```bash
# Only when config.ini is yours and trusted — never source untrusted input
. ./config.ini
echo "$KEY"
```

For untrusted config, parse with `awk` or a real INI parser — `source`
runs arbitrary shell.

## Example 40 — Log file analysis (variable reuse)

> **Source divergence.** The article uses `date -d "yesterday"`, which
> is GNU-only — on macOS/BSD that errors out. The version below uses
> portable epoch math so the same script runs on both. The lesson
> ("capture grep output once, reuse it") is unchanged.

```bash
# Before — temp file, grep'd twice, leaked on crash
YESTERDAY=$(date -j -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)
grep "$YESTERDAY" /var/log/application.log > /tmp/yesterdays_logs.txt
ERROR_COUNT=$(grep "ERROR"   /tmp/yesterdays_logs.txt | wc -l)
WARNING_COUNT=$(grep "WARNING" /tmp/yesterdays_logs.txt | wc -l)
rm /tmp/yesterdays_logs.txt

# After — capture once, reuse via echo, fewer subprocesses
YESTERDAY=$(date -j -v-1d +%Y-%m-%d 2>/dev/null || date -d "yesterday" +%Y-%m-%d)
YESTERDAYS_LOGS=$(grep "$YESTERDAY" /var/log/application.log)
ERROR_COUNT=$(grep   -c "ERROR"   <<<"$YESTERDAYS_LOGS")
WARNING_COUNT=$(grep -c "WARNING" <<<"$YESTERDAYS_LOGS")
```

Three improvements vs the source:

- `grep -c` instead of `grep | wc -l` — one process, not two.
- Here-string (`<<<`) instead of `echo "$VAR" |` — saves the `echo` fork.
- BSD `date -j -v-1d` tried first, GNU `date -d "yesterday"` as fallback.
  One line, no `if uname` branch.

**For very large logs** the variable-reuse pattern loses — bash holds
the entire grep output in memory. Switch to a single `awk` pass:

```bash
read -r ERRORS WARNS < <(awk -v d="$YESTERDAY" '
  index($0, d) {
    if (/ERROR/)   e++
    if (/WARNING/) w++
  }
  END { print e+0, w+0 }
' /var/log/application.log)
```

One read of the file, two counts, zero temp files, constant memory.

## Example 41 — Server health check

```bash
# Before — verbose extraction + repeated bc calls
MEM_FREE=$(free -m | grep "Mem:" | awk '{print $4}')
CPU_LOAD=$(uptime | awk '{print $(NF-2)}' | sed 's/,//')
DISK_FREE=$(df -h / | tail -1 | awk '{print $4}')
if [ $(echo "$MEM_FREE < 100" | bc -l) -eq 1 ]; then
  echo "Low memory: $MEM_FREE MB"
fi
# ... etc

# After — let awk do the filtering, numeric checks throughout
MEM_FREE=$(free -m | awk '/Mem:/ {print $4}')
CPU_LOAD=$(uptime | awk -F'[a-z]:' '{print $2}' | awk '{print $1}')
DISK_FREE_GB=$(df -BG / | awk 'NR==2 {sub(/G$/,"",$4); print $4}')

(( MEM_FREE < 100 ))                                       && echo "Low memory: ${MEM_FREE} MB"
(( $(echo "$CPU_LOAD > 1.0" | bc -l) ))                    && echo "High CPU load: $CPU_LOAD"
(( DISK_FREE_GB < 10 ))                                    && echo "Low disk: ${DISK_FREE_GB}G"
```

> **Source divergence.** The article ends the disk check with
> `[[ "$DISK_FREE" = "10G" ]]` — a string comparison that only fires
> when the value is *exactly* "10G", missing 9G, 1G, 500M, and every
> other low value the check is meant to catch. The version above
> normalizes to integer gigabytes and compares numerically, which is
> what the surrounding "Low memory" check does.

Three patterns to learn:

- `awk '/pattern/ {action}'` replaces `grep ... | awk '{...}'`.
- `(( numeric_test )) && cmd` for "do this if true; nothing if false."
- `df -BG` forces gigabyte units; the `awk` strips the `G` suffix so
  `(( ))` can compare it as a plain integer.

For float comparisons, `bc` stays — bash arithmetic is integer-only.
A fully-bash alternative is to multiply through:

```bash
# Compare CPU > 1.0 without bc — multiply both sides by 100
CPU_X100=${CPU_LOAD%.*}${CPU_LOAD#*.}     # "1.25" → "125"
((CPU_X100 > 100)) && echo "High CPU"
```

That's clever but fragile (assumes 2 decimal digits). Stick with `bc`
when the input format is unpredictable.

## Example 42 — Batch image processing

```bash
# Before — extra step for filename, intermediate file
for file in *.jpg; do
  filename=$(basename "$file" .jpg)
  convert "$file" -resize 50% "resized_$filename.jpg"
  convert "resized_$filename.jpg" -quality 80 "compressed_$filename.jpg"
  rm "resized_$filename.jpg"
done

# After — parameter expansion, single convert
for file in *.jpg; do
  filename=${file%.jpg}
  convert "$file" -resize 50% -quality 80 "compressed_$filename.jpg"
done
```

Two wins: `${file%.jpg}` replaces `basename ... .jpg` (and is faster), and
ImageMagick processes the chain in one invocation rather than writing to
disk between steps.

For parallel processing of large batches, see `advanced.md` Example 50.

## Example 43 — Backup script

```bash
# Before
DATE=$(date +%Y-%m-%d)
BACKUP_DIR="/backups/$DATE"
if [ ! -d "$BACKUP_DIR" ]; then
  mkdir -p "$BACKUP_DIR"
fi
tar -czf "$BACKUP_DIR/home.tar.gz" /home
tar -czf "$BACKUP_DIR/etc.tar.gz" /etc
find /backups -type d -mtime +7 -exec rm -rf {} \;

# After
BACKUP_DIR="/backups/$(date +%Y-%m-%d)"
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/home.tar.gz" /home
tar -czf "$BACKUP_DIR/etc.tar.gz" /etc
find /backups -type d -mtime +7 -delete
```

Three independent shortenings:

- Inline `$(date ...)` into the var — single use.
- Drop the `if [ ! -d ]` guard — `mkdir -p` is idempotent and atomic.
- `find -delete` instead of `-exec rm -rf {} \;` — safer (no shell
  re-entry, no traversal-while-deleting), faster, and one fewer `find`
  invocation per match.

For the two `tar` calls, brace expansion shortens further:

```bash
for src in home etc; do
  tar -czf "$BACKUP_DIR/$src.tar.gz" "/$src"
done
```

Or in parallel:

```bash
tar -czf "$BACKUP_DIR/home.tar.gz" /home &
tar -czf "$BACKUP_DIR/etc.tar.gz"  /etc  &
wait
```

## Example 44 — User management

> **Source divergence.** The article shortens the inner `if/else` with
> `cmd && echo A || echo B`. That pattern fires *both* `A` and `B` if
> `cmd` succeeds but `A` happens to fail — a footgun that bites the
> moment the right-hand side gains side effects. The version below
> keeps the `if`/`else` for the branching decision and uses inline
> `&&` only for guards (where there's no `||` branch to misfire).

```bash
# Before — nested ifs, deep indentation
if id "$USERNAME" &>/dev/null; then
  echo "User exists"
  if groups "$USERNAME" | grep -q "admin"; then
    echo "User is admin"
  else
    echo "User is not admin"
  fi
else
  echo "User does not exist"
fi

# After — early return flattens the nesting
id "$USERNAME" &>/dev/null || { echo "User does not exist"; return 1; }
echo "User exists"
if groups "$USERNAME" | grep -q "admin"; then
  echo "User is admin"
else
  echo "User is not admin"
fi
```

Two real wins, no footgun:

- The `|| { ...; return 1; }` form handles the "early exit" case in one
  line, dropping the outer `if`/`else` entirely.
- The remaining `if`/`else` is for *branching*, not a guard — which is
  the case where `&&`/`||` is dangerous to chain.

If this lives at script-top-level rather than inside a function, swap
`return 1` for `exit 1`. If you need to *not* exit on missing user,
keep the original nested form — early return only works when "user
missing" is genuinely terminal.

## Example 45 — API request with `jq` error handling

> **Source divergence.** The article's "After" version uses
> `curl -s` (which silently returns the body even on 4xx/5xx) and
> `jq -r '.error'` (which prints the literal string `null` when the
> field is missing — false-positive). The version below uses `curl -f`
> to fail-fast on HTTP errors and `// empty` to make missing fields
> return empty. Same teaching points (`<<<` here-string, structural
> check, fall-through), production-grade behavior.

```bash
# Before — string match for error, repeated extraction, no HTTP check
RESPONSE=$(curl -s https://api.example.com/data)
if echo "$RESPONSE" | grep -q "error"; then
  ERROR=$(echo "$RESPONSE" | jq -r '.error')
  echo "Error: $ERROR"
  exit 1
else
  DATA=$(echo "$RESPONSE" | jq -r '.data')
  echo "Data: $DATA"
fi

# After — fail-fast HTTP, structural error check, here-string
RESPONSE=$(curl -sf https://api.example.com/data) || {
  echo "HTTP request failed" >&2
  exit 1
}
ERROR=$(jq -r '.error // empty' <<<"$RESPONSE")
[[ -n $ERROR ]] && { echo "Error: $ERROR" >&2; exit 1; }
echo "Data: $(jq -r '.data' <<<"$RESPONSE")"
```

Four improvements over the source:

- `curl -f` makes 4xx/5xx fail (so the `||` block fires); `-s` alone
  hides the error code and you process garbage as if it were valid JSON.
- `jq -r '.error // empty'` returns empty string when `.error` is
  missing — without `// empty` you'd get the literal `"null"` and the
  error path would always fire.
- `<<<"$RESPONSE"` is a here-string — feeds the value as stdin without
  spawning `echo`.
- The "no error" path falls through after `exit 1`, eliminating the
  `else` block.
