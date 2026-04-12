---
name: ralphify-spec
description: Generate a ralphify-approved ralph directory (RALPH.md + optional scripts) from a plain-English description of repetitive or iterative work. Use this skill whenever the user says "ralphify", "create a ralph", "ralph wiggum", "autonomous loop", "/ralphify", references Geoffrey Huntley's Ralph Wiggum method, or asks to wrap iterative work in ralphify (test-until-green, refactor-until-done, lint-until-clean, coverage-until-90, burn-down-todos, resolve-review-comments). Trigger even when the user does not explicitly name ralphify but describes an open-ended loop ("keep fixing tests until they pass", "port files one by one until the directory is done"). Do not trigger for one-shot tasks — ralphs exist for work that benefits from running N times against a stop condition.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# ralphify-spec

Translate a plain-English iterative task into a valid, runnable ralphify ralph directory — a `RALPH.md` with well-formed YAML frontmatter, useful command blocks, and a prompt body that follows the Ralph Wiggum method.

The user does not need to know how ralphify works. Do not explain frontmatter, placeholders, or shlex quirks to them. Translate their goal into a working ralph and hand them the suggested run command.

## When this fits

Ralphs pay off for work where each iteration makes incremental progress and a stop condition tells the loop when to halt:

- climb test coverage to a threshold
- burn down lint or type-check errors
- port files from one language/framework to another
- resolve PR review comments one by one
- work through a TODO list until empty

If the task is one-shot ("add a button to this page", "explain this function"), a ralph adds nothing. Recommend `/fromage` or direct implementation and stop.

## Workflow

### 1. Capture intent (2-3 questions, maximum)

Ask only what you cannot already infer from the conversation or the current working directory. Skip questions the user already answered.

1. **What does "done" look like for one full run?** (coverage above 90%, zero clippy warnings, all review threads resolved, etc.) This becomes the stop condition and drives which commands the ralph surfaces each iteration.
2. **What language and tools?** Enough to pick test and lint commands — inspect `pyproject.toml`, `Cargo.toml`, or `package.json` first and only ask if ambiguous.
3. **Any hard constraints?** Files or directories to leave alone, commit format, style guide. Ask only if non-obvious.

Do **not** ask about command blocks, frontmatter fields, placeholders, or YAML. That is your job.

### 2. Pick a name and location

- Derive a short kebab-case name from the task ("coverage-climber", "ts-porter", "clippy-burndown") unless the user provided one. The validator (step 7) enforces the exact character set ralphify accepts.
- Default location: `ralphs/<name>/` inside the current repo. Confirm only if the cwd is not a sensible home for it.

### 3. Scaffold from the canonical template, then rewrite

Start from ralphify's own canonical template so the file parses and you begin from the upstream-endorsed shape:

```bash
ralph init ralphs/<name>
```

If `ralph` is not on `PATH`, fall back to `~/.local/bin/ralph` — that is where `uv tool install ralphify` places the binary. After scaffolding, rewrite the file for the user's task rather than shipping the stock template.

### 4. Design the frontmatter

`REFERENCE.md` is the schema spec. Read it when you need exact rules (required vs optional fields, constraints, defaults). Don't re-derive them from this skill body.

Default agent: `claude -p --dangerously-skip-permissions`, unless the user is on a different agent (Gemini, Cursor agent, etc.).

#### Guard scripts (short-circuit pattern)

When the ralph has a clear "all done" condition checkable before spinning up an agent, wrap the agent call in a guard script and point `agent:` at the script instead:

```bash
#!/usr/bin/env bash
# guard.sh — exit 1 to stop ralphify before wasting an agent iteration
set -euo pipefail

TODO="$(dirname "$0")/TODO.md"
if ! grep -q '^\- \[ \]' "$TODO" 2>/dev/null; then
  echo "No unchecked items — stopping." >&2
  exit 1
fi

exec claude -p --dangerously-skip-permissions "$@"
```

```yaml
agent: ./guard.sh
```

The guard runs before the agent, so a failed pre-condition skips the iteration entirely (no token cost). Use this when a `check-done.sh` command would still burn an agent invocation just to see "nothing to do". Common guards: grep for remaining TODOs, check coverage threshold, verify lint error count > 0.

Set `credit: false` if the repo forbids automated commit trailers — by default ralphify appends a co-author instruction to each iteration's prompt.

Default `commands` picks by stack:

- any repo: `git-log` → `git log --oneline -10`
- Python: `tests` → `uv run pytest`, `lint` → `uv run ruff check .`
- Rust: `tests` → `cargo test`, `lint` → `cargo clippy --all-targets -- -D warnings`
- Node/TypeScript: `tests` → `npm test`, `lint` → `npm run lint`
- stop-condition probes: write a script (see step 5) and reference it as `./check-done.sh`

Add `args` only if the ralph is meant to be reusable across targets (`module`, `dir`, `issue`). When in doubt, hardcode — generalizing later is cheap.

### 5. Shell features belong in scripts

`commands[].run` is parsed with `shlex.split`. Shell features (pipes, `&&`, redirects, `$(...)`) parse fine but fail at runtime — see REFERENCE.md for the exhaustive metachar list. When you need any of them, write a script in the ralph directory and reference it with `./name.sh`:

```yaml
commands:
  - name: coverage
    run: ./check-coverage.sh
```

- Make the script executable (`chmod +x`).
- Scripts invoked via `./` prefix run with the ralph directory as cwd; commands without the prefix run from the project root.
- Keep scripts short and single-purpose — the agent only sees their output.

### 6. Write the prompt body

The body is the prompt piped to the agent every iteration, with `{{ commands.X }}`, `{{ args.X }}`, and `{{ ralph.X }}` resolved. Because each iteration starts with a fresh context, the prompt must re-establish enough situation every time to be useful. Follow the ralphify-canonical shape:

1. **Role + loop awareness.** "You are an autonomous <role> agent running in a loop." This primes the agent that it is not having a conversation. Include `## Iteration: {{ ralph.iteration }}` so the agent knows where it is in the loop — useful for "on final iteration, do cleanup" logic.
2. **Context-reset acknowledgment.** "Each iteration starts with a fresh context. Your progress lives in the code and git." This stops the agent from trying to remember state across turns.
3. **Command output sections.** Put `{{ commands.<name> }}` under `## <Title>` headers. The agent can only see what the prompt shows it — if it needs to see failing tests, the prompt needs a `## Test results` section.
4. **Task section.** State exactly what one iteration of work is. Narrow beats broad: "add tests for one untested function" beats "improve coverage". A fresh-context agent should be able to pick a target and finish it within a single iteration.
5. **Rules.** Bulleted list — what to avoid, what to always do, the stop condition.
6. **Commit conventions.** One commit per iteration, format (Conventional Commits or whatever the repo uses), push or not.

Use HTML comments (`<!-- ... -->`) for notes to yourself about why a rule exists or TODOs for prompt maintenance — ralphify strips them before piping to the agent, so they never waste tokens.

### 7. Validate with the bundled script

Run the bundled validator against the draft. It is the gate — do not skip it, and do not try to mentally re-implement what it checks:

```bash
uv run --with pyyaml python ~/.claude/skills/ralphify-spec/scripts/validate.py <ralph-path>/RALPH.md
```

It enforces the schema rules in `REFERENCE.md` — required fields, name regex, shlex safety, placeholder coverage, agent binary on PATH, timeout type. Exit 0 = clean (warnings are advisory), exit 1 = errors that must be fixed before reporting back, exit 2 = environment problem.

Pay attention to the warnings — declared-but-unused commands or args are usually cleanup signals. The `ralph init` scaffold ships with `args: [focus]` that you almost certainly need to remove if you scaffolded from it.

### 8. Report back

Show the user:

1. **File tree** of the created directory.
2. **One sentence** describing what a single iteration will do.
3. **Suggested first run:** `ralph run <path> -n 3 -t 600 -s -l <path>/logs` — three iterations, ten-minute timeout, stop on error, logs captured. Starting with `-n 3` lets them see the loop work before going unbounded.
4. **Shortcut:** mention the `rw` shell function (defined in `zsh/claude.zsh`) — `rw ralphs/<name>` is exactly the suggested command above. To run more iterations: `rw ralphs/<name> -n 10`.

## Example output

```
ralphs/coverage-climber/
├── RALPH.md
└── check-coverage.sh
```

`RALPH.md`:

```yaml
---
agent: claude -p --dangerously-skip-permissions
commands:
  - name: git-log
    run: git log --oneline -10
  - name: tests
    run: uv run pytest
  - name: coverage
    run: ./check-coverage.sh
---

You are an autonomous Python testing agent running in a loop. Each iteration starts with a fresh context. Your progress lives in the code and git.

## Iteration: {{ ralph.iteration }}

## Recent changes

{{ commands.git-log }}

## Test results

{{ commands.tests }}

If any tests above are failing, fix them before writing new tests.

## Coverage

{{ commands.coverage }}

## Task

Pick one untested function in `src/` and add tests for it. One function per iteration — the goal is steady progress, not breadth.

## Rules

- Do not modify `src/` beyond what is needed to make code testable (dependency injection, extract helpers).
- Do not edit generated files or `tests/fixtures/`.
- Stop when the coverage script reports >= 90%.
- One commit per iteration.

## Commit

Conventional Commits: `test(<module>): cover <function>`.
```

`check-coverage.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
uv run coverage report --format=total
```

## What not to do

- Do not invent frontmatter fields ralphify does not support. The schema is small on purpose — anything outside `agent`, `commands`, `args`, `credit` is noise.
- Do not pipe or chain commands in `run:`. Use a script instead.
- Do not leave placeholders without a matching declaration — they render as literal text and confuse the agent.
- Do not ask the user about ralphify internals. If they wanted to write YAML they would not be here.
- Do not default to `-n` unbounded on the first run. Start with `-n 3` so the user can see the loop work before committing to unbounded runs.
