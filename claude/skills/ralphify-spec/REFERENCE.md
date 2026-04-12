# RALPH.md field reference

Authoritative reference for the ralphify frontmatter schema (v0.3.0). Cross-reference when you need the exact rule rather than the summary in `SKILL.md`. If a rule below disagrees with the installed `ralphify` package, the package wins — re-derive from its `_frontmatter.py` and `cli.py`.

## Frontmatter

### `agent` (required, string)

The full shell command ralphify pipes the assembled prompt into on each iteration. The first token must resolve on `PATH` at runtime or ralphify refuses to start.

Examples:

- `claude -p --dangerously-skip-permissions`
- `gemini -p --yolo`
- `cursor-agent -p`
- `./guard.sh` — a wrapper script that checks a pre-condition before `exec`ing the real agent (short-circuit pattern; see below)

#### Guard script pattern

Point `agent:` at a script that checks whether work remains before invoking the agent. If the check fails, the script exits non-zero and ralphify skips the iteration (no token cost). The script receives the assembled prompt on stdin via `"$@"`.

```bash
#!/usr/bin/env bash
set -euo pipefail
TODO="$(dirname "$0")/TODO.md"
if ! grep -q '^\- \[ \]' "$TODO" 2>/dev/null; then
  echo "No unchecked items — stopping." >&2
  exit 1
fi
exec claude -p --dangerously-skip-permissions "$@"
```

### `commands` (optional, list)

List of command entries. Each command runs once per iteration; its combined stdout and stderr become available in the body via `{{ commands.<name> }}`.

Entry fields:

| Field | Required | Type | Default | Notes |
|-------|----------|------|---------|-------|
| `name` | yes | string | — | regex `[a-zA-Z0-9_-]+`, unique across all commands |
| `run` | yes | string | — | parsed by `shlex.split` — no shell features. Paths starting `./` resolve relative to the ralph directory |
| `timeout` | no | number | 60 | seconds before the command is killed |

**Shell features are not supported in `run`.** No `|`, `&&`, `||`, `;`, redirects, backticks, or `$(...)`. For anything non-trivial, write a script in the ralph directory and reference it with `run: ./script.sh`.

**Output is captured regardless of exit code.** A failing command still produces output the agent can see — useful for surfacing test failures.

**`{{ args.<name> }}` works inside `run` strings.** Placeholders are resolved before execution: `run: gh issue view {{ args.issue }}` becomes `gh issue view 42` at runtime.

### `args` (optional, list of strings)

Declared CLI argument names. Used as positional arguments (`ralph run my-ralph ./src "perf"` with `args: [dir, focus]`) or named flags (`--dir ./src --focus perf`). Each name must match `[a-zA-Z0-9_-]+` and be unique.

Referenced in the body and in `run:` strings as `{{ args.<name> }}`. Missing arguments resolve to empty strings, not errors.

### `credit` (optional, bool, default true)

When true, ralphify appends a co-author trailer instruction to every iteration's prompt (telling the agent to co-author commits with ralphify). Set to `false` to suppress — useful for repos that forbid automated trailers.

## Body placeholders

All placeholder types are resolved in a single pass, so a command's output cannot contain `{{ ... }}` syntax and have it re-expanded. That is intentional — it keeps command output from accidentally injecting into the prompt.

### `{{ commands.<name> }}`

Replaced with the combined stdout + stderr of the named command as captured that iteration.

### `{{ args.<name> }}`

Replaced with the CLI argument value. Missing args become empty strings.

## HTML comments

`<!-- ... -->` blocks are stripped from the body before the prompt is assembled. Safe for maintenance notes, TODOs, or rationale for rules — none of it reaches the agent or costs tokens.

## Ralph directory layout

```
my-ralph/
├── RALPH.md              # required
├── check-coverage.sh     # optional script, referenced as ./check-coverage.sh
├── style-guide.md        # optional reference file
└── fixtures.json         # any supporting file
```

Only `RALPH.md` is required. Scripts must be executable (`chmod +x`). Scripts invoked via the `./` prefix run with the ralph directory as cwd; commands without the prefix run from the project root (the cwd where `ralph run` was invoked).

## CLI commands

| Command | Purpose |
|---------|---------|
| `ralph init [name]` | scaffold the canonical template (quickest starting point) |
| `ralph add owner/repo[/name]` | fetch a ralph from GitHub |
| `ralph run <path> [flags]` | run the loop |

`ralph run` flags:

- `-n, --max-iterations INT` — cap iterations; infinite if unset
- `-t, --timeout FLOAT` — max seconds per agent iteration
- `-l, --log-dir DIR` — save per-iteration output to a directory
- `-s, --stop-on-error` — halt if the agent exits non-zero or times out
- `-d, --delay FLOAT` — seconds between iterations

Extra `--flag value` pairs and positional arguments after `<path>` are exposed to the ralph as `{{ args.flag }}` and resolved into the prompt.
