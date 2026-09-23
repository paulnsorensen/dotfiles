# Advanced patterns

Examples 48-51 from the source article. These are the patterns that mark
a script as written by someone who actually knows bash, rather than
someone who learned it as they went.

## Example 48 — Heredocs for multi-line strings

```bash
# Before
echo "Usage: $0 [options]"
echo "Options:"
echo "  -h    Show help"
echo "  -v    Show version"
echo "  -f    Force operation"

# After
cat <<EOF
Usage: $0 [options]
Options:
  -h    Show help
  -v    Show version
  -f    Force operation
EOF
```

Heredoc variants — pick by what you need to interpolate:

```bash
# Interpolate vars and command substitution (default)
cat <<EOF
Today: $(date)
User: $USER
EOF

# NO interpolation (quoted delimiter — literal $)
cat <<'EOF'
This stays as a literal: $USER, $(date), `cmd`
EOF

# Indented for in-function readability (uses <<- and strips LEADING TABS).
# The lines between the delimiters MUST be tab-indented in your editor —
# spaces are not stripped. Shown here with → marking each tab:
my_func() {
    cat <<-EOF
    →This line starts at column 1 in output.
    →Tabs (not spaces) at the start of each line are stripped.
    →EOF
}

# Send to a command's stdin
mysql -u user mydb <<EOF
INSERT INTO t VALUES (1, 'a');
INSERT INTO t VALUES (2, 'b');
EOF

# Capture into a variable
USAGE=$(cat <<EOF
line 1
line 2
EOF
)
```

The `<<-` form is the readable choice inside indented blocks, but it
*only* strips tab indentation — spaces don't work. Editors that convert
tabs to spaces will silently break this; configure for tabs in heredocs
or use the unindented form.

For a single line of output, prefer `printf '%s\n' "..."` over `echo` —
`printf` is consistent across shells and handles backslash escapes
predictably.

## Example 49 — Associative arrays (bash 4+)

```bash
# Before — long if/elif chain
if [ "$ENV" = "dev" ]; then
  URL="https://dev.example.com"
elif [ "$ENV" = "staging" ]; then
  URL="https://staging.example.com"
elif [ "$ENV" = "prod" ]; then
  URL="https://prod.example.com"
else
  URL="https://localhost"
fi

# After — declarative lookup
declare -A URLS=(
  [dev]="https://dev.example.com"
  [staging]="https://staging.example.com"
  [prod]="https://prod.example.com"
)
URL=${URLS[$ENV]:-https://localhost}
```

The `${URLS[$ENV]:-default}` form falls back when `$ENV` isn't a defined
key. This is also how you avoid the noisy "unbound variable" error under
`set -u`:

```bash
set -u
URL=${URLS[$ENV]:-https://localhost}     # works even if $ENV unset
```

**Iteration:**

```bash
for env in "${!URLS[@]}"; do        # !URLS[@] = the keys
  echo "$env -> ${URLS[$env]}"
done
```

**Caveats:**

- Requires bash 4+ — macOS ships 3.2 by default. Either install bash 4+
  via Homebrew (`brew install bash`) or use a `case` statement instead.
- `declare -A` must come *before* assignment. `URLS=(...)` without the
  declare creates an indexed array.

For 3-5 cases, `case` is just as readable as an associative array and
works on bash 3.2:

```bash
case $ENV in
  dev)     URL="https://dev.example.com" ;;
  staging) URL="https://staging.example.com" ;;
  prod)    URL="https://prod.example.com" ;;
  *)       URL="https://localhost" ;;
esac
```

Reach for associative arrays when the mapping has 6+ entries, when keys
are computed at runtime, or when you need to iterate over the keys.

## Example 50 — Parallel execution with `wait`

```bash
# Before — sequential
for server in server1 server2 server3 server4; do
  ssh "$server" "apt-get update && apt-get upgrade -y"
done

# After — backgrounded with `&`, then `wait`
for server in server1 server2 server3 server4; do
  ssh "$server" "apt-get update && apt-get upgrade -y" &
done
wait
```

The article's 20→5 minute claim assumes the work is bottlenecked on the
remote side (network, remote CPU). Local-CPU-bound work doesn't scale
the same way past your core count.

**Important upgrades the article omits:**

```bash
# Capture each child's exit so one failure doesn't get silently dropped
declare -A pids
for server in server1 server2 server3 server4; do
  ssh "$server" "apt-get update && apt-get upgrade -y" &
  pids[$server]=$!
done

failures=0
for server in "${!pids[@]}"; do
  if ! wait "${pids[$server]}"; then
    echo "FAIL: $server" >&2
    ((failures++)) || true       # see arithmetic.md set -e gotcha
  fi
done
exit $((failures > 0))
```

This catches per-host failures rather than reporting only the last one.
For more than ~10 parallel jobs, switch to `xargs -P` or GNU `parallel`:

```bash
printf '%s\n' server1 server2 server3 server4 \
  | xargs -I {} -P 4 ssh {} "apt-get update && apt-get upgrade -y"
```

`-P 4` caps parallelism at 4. Use this when you have 100 servers and
don't want 100 simultaneous SSH sessions.

**Output interleaving** is the other gotcha. With `&`, all four ssh
sessions write to your terminal at once. Capture per-host:

```bash
for server in server1 server2 server3 server4; do
  ssh "$server" "apt-get update && apt-get upgrade -y" \
    > "logs/${server}.out" 2> "logs/${server}.err" &
done
wait
```

## Example 51 — Custom IFS for structured input

```bash
# Before — manual cut for each field
cat data.csv | while read -r line; do
  field1=$(echo "$line" | cut -d, -f1)
  field2=$(echo "$line" | cut -d, -f2)
  field3=$(echo "$line" | cut -d, -f3)
  echo "Processing $field1, $field2, $field3"
done

# After — IFS does the splitting
while IFS=, read -r field1 field2 field3; do
  echo "Processing $field1, $field2, $field3"
done < data.csv
```

`IFS=,` in front of `read` sets the field separator for *that command
only* — it's not exported to the rest of the script. Three subprocesses
per line collapse to zero.

For other separators:

```bash
# Tab-separated
while IFS=$'\t' read -r a b c; do ...; done < data.tsv

# Pipe-separated
while IFS='|' read -r a b c; do ...; done < data.psv

# Multiple separators (any of them splits)
while IFS=',;|' read -r a b c; do ...; done < messy.txt
```

**Real-world CSV warning.** `IFS=, read` does not handle quoted commas,
escaped quotes, or embedded newlines. For RFC 4180 CSV (the kind
spreadsheets export), use a real parser:

```bash
# csvkit — pip install csvkit
csvcut -c name,email data.csv

# Miller (mlr) — brew install miller
mlr --csv cat data.csv

# python one-liner
python3 -c 'import csv,sys; [print(r) for r in csv.reader(sys.stdin)]' < data.csv
```

`IFS=,` is right for *simple* CSV where you control the input (config
files, system log exports). For data that came from humans or
spreadsheets, use a tool that knows the spec.

**Drop empty lines:**

```bash
while IFS=, read -r a b c; do
  [[ -z $a$b$c ]] && continue
  ...
done < data.csv
```

**Skip the header:**

```bash
{ read -r _; while IFS=, read -r a b c; do ...; done; } < data.csv
```

The first `read` consumes the header into `$_` (ignored), the loop
processes the rest. The braces group both reads against the same input
redirection.
