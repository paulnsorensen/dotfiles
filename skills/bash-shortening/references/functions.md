# Functions

Examples 16-20 from the source article. Functions are the right shortening
tool when you've copy-pasted the same 3+ lines twice. Below ~3 lines of
duplication, inline is usually clearer than function indirection.

## Example 16 — Logging function

```bash
# Before — repeated each call site
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] [INFO] Message" >> /var/log/app.log
echo "[$(date +%Y-%m-%d\ %H:%M:%S)] [ERROR] Error message" >> /var/log/app.log

# After
log() {
  local level="${1^^}"                      # uppercase the level
  local message="$2"
  echo "[$(date +%Y-%m-%d\ %H:%M:%S)] [$level] $message" >> /var/log/app.log
}

log info  "Message"
log error "Error message"
```

Two patterns to notice:

- `local` keeps `level` and `message` from leaking into the surrounding
  scope. *Always* use `local` for function-internal vars.
- `${1^^}` uppercases — bash 4+. For older bash or `/bin/sh`, use
  `tr '[:lower:]' '[:upper:]'`.

A more honest version routes by level:

```bash
log() {
  local level="${1^^}" message="$2"
  local ts; ts=$(date +"%Y-%m-%d %H:%M:%S")
  case "$level" in
    ERROR|FATAL) echo "[$ts] [$level] $message" >&2 ;;
    *)           echo "[$ts] [$level] $message" ;;
  esac
}
```

That sends errors to stderr (where they belong) without changing the call
sites.

## Example 17 — Defaults via parameter expansion

```bash
# Before
deploy() {
  local environment=$1
  if [ -z "$environment" ]; then
    environment="dev"
  fi
  echo "Deploying to $environment"
}

# After
deploy() {
  local environment=${1:-dev}
  echo "Deploying to $environment"
}
```

The `local environment=${1:-dev}` form combines declaration, scoping, and
default in one line. Pairs naturally with parameter expansion (see
`parameter-expansion.md`).

## Example 18 — Inline conditional instead of one-line function

```bash
# Before
check_dir() {
  if [ ! -d "$1" ]; then
    mkdir -p "$1"
  fi
}
check_dir "/tmp/app"

# After
[ -d "/tmp/app" ] || mkdir -p "/tmp/app"

# Even simpler — mkdir -p is idempotent
mkdir -p "/tmp/app"
```

The article shows the `||` form; the *better* version recognizes that
`mkdir -p` already does the existence check internally. The shortening
isn't `if` → `||`, it's "delete the redundant guard entirely."

When you do reach for `&&` / `||`:

- `cmd1 && cmd2` runs `cmd2` only if `cmd1` succeeded.
- `cmd1 || cmd2` runs `cmd2` only if `cmd1` failed.
- **Don't chain as `cmd1 && cmd2 || cmd3`** to mean if/then/else. If
  `cmd2` fails, `cmd3` still runs. Use `if`/`else` for non-trivial branches.

## Example 19 — Return values via echo

Bash functions can't return values directly — `return N` only sets the
exit status (0-255). The convention is `echo` the value and capture it.

```bash
# Before — redundant intermediate
get_status() {
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$URL")
  echo "$STATUS"
}
STATUS=$(get_status)

# After — direct echo
get_status() {
  curl -s -o /dev/null -w "%{http_code}" "$URL"
}
STATUS=$(get_status)
```

**Gotcha:** if your function might `echo` debug info to stdout, the caller
catches that too. Either send debug to stderr (`echo "..." >&2`) or use a
named global:

```bash
_RESULT=
get_status() {
  _RESULT=$(curl -s -o /dev/null -w "%{http_code}" "$URL")
}
get_status; echo "Status: $_RESULT"
```

The `_RESULT=` convention (leading underscore) signals "implementation
detail, treat as private."

## Example 20 — Named parameters via `--flag=value` parsing

For functions with 3+ parameters, positional args become unreadable at
the call site:

```bash
# Before — what is `true`?
create_user "john" "secret" true

# After — self-documenting
create_user --username=john --password=secret --admin=true
```

Implementation:

```bash
create_user() {
  local username= password= is_admin=false
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --username=*) username="${1#*=}" ;;
      --password=*) password="${1#*=}" ;;
      --admin=*)    is_admin="${1#*=}" ;;
      *)            echo "Unknown arg: $1" >&2; return 1 ;;
    esac
    shift
  done
  # ... create user ...
}
```

The `${1#*=}` strips everything up to and including the first `=`,
leaving just the value. (See `parameter-expansion.md` for `#` semantics.)

For richer CLI parsing inside a function, `getopts` handles short flags
(`-u`, `-p`); for long flags, the manual loop above is the standard
pattern.

## When NOT to extract a function

- **Used once.** A function used in one place is often clearer inlined.
- **Three lines or less, no logic.** `mkdir -p "$dir"` doesn't need a
  `make_dir() { mkdir -p "$1"; }` wrapper.
- **Pure passthrough.** `wrap_curl() { curl "$@"; }` adds nothing.
- **Hides a one-liner that's already idiomatic.** `is_set() { [ -n "$1" ]; }`
  is *less* readable than `[ -n "$VAR" ]` at the call site.

The right test: does the function name communicate intent that the inline
code doesn't? If yes, extract. If the name is just a restatement of the
code, inline.

## Function safety scaffolding

For non-trivial functions, lead with:

```bash
my_func() {
  local arg1=${1:?missing arg1}    # fail-fast on missing required arg
  local arg2=${2:-default}
  local OLD_IFS=$IFS               # save & restore IFS if you change it
  trap 'IFS=$OLD_IFS' RETURN
  # ...
}
```

`${1:?msg}` exits with the message if `$1` is unset/empty — the bash
equivalent of an assertion.
