# Anti-patterns: When NOT to shorten

Shortening is a tool, not a goal. The article opens with two examples
showing *why* shortening matters, then closes with two showing where it
hurts. Both ends of the spectrum are codified here.

## The cost of verbosity (Example 1)

Verbose code hides its intent under ceremony.

```bash
# Verbose approach (7 lines, hard to follow)
TEMP_DIR="/tmp/myapp"
LOG_FILE="$TEMP_DIR/app.log"
if [ ! -d "$TEMP_DIR" ]; then
  mkdir -p "$TEMP_DIR"
fi
echo "Application started at $(date)" > "$LOG_FILE"
./myapp >> "$LOG_FILE" 2>&1

# Shortened approach (3 lines, clear intent)
LOG_FILE="/tmp/myapp/app.log"
mkdir -p "$(dirname "$LOG_FILE")"
echo "Application started at $(date)" > "$LOG_FILE" && ./myapp >> "$LOG_FILE" 2>&1
```

Three wins: no redundant `TEMP_DIR` variable, no race-prone existence
check (`mkdir -p` is idempotent), and the launch line reads as a single
intent ("init log, then run app").

## Readability through structure (Example 2)

Shortening doesn't mean stuffing everything onto one line.

```bash
# Before — cluttered semicolon chain
if [ "$ENV" == "production" ]; then URL="https://api.example.com"; elif [ "$ENV" == "staging" ]; then URL="https://staging.example.com"; else URL="https://dev.example.com"; fi

# After — case statement, structured
case "$ENV" in
  production) URL="https://api.example.com" ;;
  staging)    URL="https://staging.example.com" ;;
  *)          URL="https://dev.example.com" ;;
esac
```

The `case` form is *longer in characters* than the one-liner, but it's
"shorter" in cognitive load. That's the right axis to optimize.

For 3+ branches with simple value lookup, `case` is good and an
associative array (see `advanced.md` Example 49) is even better.

## Overly complex one-liners (Example 46)

```bash
# Too shortened (cryptic)
find . -type f -name "*.log" | xargs grep -l "ERROR" | while read -r f; do d=$(dirname "$f"); mkdir -p "/archive/$d" && cp "$f" "/archive/$d/" && rm "$f"; done

# Better — multi-line, named variables
find . -type f -name "*.log" | xargs grep -l "ERROR" | while read -r file; do
  dir=$(dirname "$file")
  mkdir -p "/archive/$dir"
  cp "$file" "/archive/$dir/"
  rm "$file"
done
```

The cryptic version saves five line breaks and costs every future reader
30 seconds of parsing. Trade is bad.

## Cryptic parameter expansion chains (Example 47)

```bash
# Too shortened
CMD=${1:-${DEF_CMD:-ls}}; [[ ${2:+x} ]] && ARGS=${2//,/ } || ARGS="-la"; $CMD $ARGS

# Better
CMD=${1:-${DEF_CMD:-ls}}      # provided cmd, env default, or 'ls'
if [[ -n "$2" ]]; then
  ARGS=${2//,/ }              # commas → spaces
else
  ARGS="-la"
fi
$CMD $ARGS
```

Nested parameter expansions are individually fine. *Stacked* with
inline conditionals on one line, they cross the line into write-only code.

## Calibration heuristics

Use these when deciding "should I shorten this further?":

1. **Read it cold.** If you have to mentally parse the line in two passes,
   it's too dense. Break it up.
2. **Count the operators per line.** More than ~4 of `$( )`, `${ }`, `&&`,
   `||`, `${var:-...}`, `<( )` on one line is a smell.
3. **Naming saves more than nesting.** A named intermediate variable used
   in three places beats inlining the expression three times — even though
   inlining is "shorter" on the line count.
4. **Comments are a tell.** If your shortened version needs a `# what this
   does` comment to be read, the next reader will skip the comment, get
   confused, and rewrite it verbosely. Pre-empt them.

## POSIX portability checklist

If the script targets `#!/bin/sh` (Alpine, BusyBox, install scripts, init
scripts), these bashisms break:

| Bashism | POSIX alternative |
|---|---|
| `[[ ... ]]` | `[ ... ]` (mind quoting) |
| `${var//x/y}` (replace all) | `echo "$var" \| sed 's/x/y/g'` |
| `${var:0:5}` (substring) | `echo "$var" \| cut -c1-5` |
| `(( arith ))` | `[ "$(( arith ))" -ne 0 ]` (use `$(( ))` only, not `(( ))`) |
| `<(cmd)` (process sub) | Temp file with `mktemp` + `trap rm` |
| `${var^^}` (uppercase) | `echo "$var" \| tr '[:lower:]' '[:upper:]'` |
| `arr=(a b c); ${arr[1]}` | Positional params (`set -- a b c; echo $2`) |
| `declare -A` (assoc array) | Not available — use `case` or two parallel arrays |
| `read -r ... <<<"$var"` | `echo "$var" \| read -r ...` (subshell — vars don't escape) |

When in doubt, run `shellcheck -s sh script.sh` — it flags every bashism.

## What this skill never does

- Doesn't golf scripts past readability for the sake of brevity.
- Doesn't strip `set -euo pipefail`, `trap`, or other safety scaffolding
  while shortening.
- Doesn't replace explicit `if`/`else` with `&&`/`||` when the first
  branch can legitimately fail (the `||` would fire on success+failure).
- Doesn't assume bash availability when the shebang says otherwise.
