---
name: make
model: haiku
context: fork
allowed-tools: Bash(*), Read, Glob, Grep
description: >
  You cannot run build commands (cargo check, cargo clippy, go build, npm run build,
  just check, tsc, pytest, etc.) directly — hooks will block them and raw compiler
  output floods your context window. This skill is the ONLY way to verify code
  compiles, run linters, execute tests, or check formatting. It runs in a forked
  subagent that absorbs all verbose output and returns only structured file:line:col
  errors. Auto-detects build system (just, cargo, npm, go, make, cmake, gradle,
  maven, uv/python). Triggers automatically when you need to: check if code compiles
  after edits, verify a refactor didn't break anything, run clippy/eslint/ruff, run
  tests, check formatting, clean build artifacts, or fix a CI failure. Also triggers
  on /make, /build, /check, /compile. Subcommands: /make test, /make lint, /make fmt,
  /make clean. If a hook blocks a build command, invoke this skill immediately.
---

# make

Run builds. Return signal, not noise.

Your job: execute a build/check command, absorb the full compiler output in your own
context, and return ONLY structured errors and warnings to the caller. All the verbose
log lines, progress bars, and passing-module output stay trapped here — never reaching
the main context window.

## Arguments

| Invocation | Action |
|---|---|
| `/make` or no args | Detect build system, run default check/build |
| `/make check` | Alias for `/make` — type-check without full build |
| `/make build` | Full build (not just type-check) |
| `/make test` | Run test suite (detect framework, return pass/fail + failures) |
| `/make lint` | Run linter (clippy, ruff, eslint — stricter than check) |
| `/make fmt` | Run formatter in check mode (report unformatted files) |
| `/make clean` | Clean build artifacts |
| `/make <file>` | Check a specific file if the build system supports it |

## Step 1: Detect Build System

Check the project root for marker files in priority order. Use the FIRST match:

| Marker | Tool | Default Command |
|---|---|---|
| `Justfile` | just | `just check` (or `just build` if no `check` recipe) |
| `Cargo.toml` | cargo | `cargo check --message-format=short 2>&1` |
| `package.json` | npm/bun/pnpm | `npm run build 2>&1` (if `build` script exists) |
| `go.mod` | go | `go build ./... 2>&1` |
| `pyproject.toml` | python/uv | `uv run mypy . 2>&1` or `uv run python -m py_compile <file>` |
| `Makefile` | make | `make check 2>&1` (if `check` target exists, else `make 2>&1`) |
| `CMakeLists.txt` | cmake | `cmake --build build 2>&1` |
| `build.gradle*` | gradle | `./gradlew build 2>&1` |
| `pom.xml` | maven | `mvn compile -q 2>&1` |

**Detection rules:**
- For `Justfile`: read it to check which recipes exist. Prefer `check` > `build` > `test`.
  If `check` wraps `cargo check` internally, that's fine — don't double-detect.
- For `Makefile`: read it and check for `check` target first, then default target.
- For `package.json`: read it and check `scripts` for a `build` entry. If none exists,
  try `tsc --noEmit` for TypeScript projects (check for `tsconfig.json`).
- For `pyproject.toml`: check if `mypy` is a dependency. If not, fall back to `ruff check`.
- Always prefer `uv run` over bare `python` / `pip` / `mypy` (user preference).
- Prefer `bun` over `npm` if `bun.lockb` exists.
- Prefer `pnpm` over `npm` if `pnpm-lock.yaml` exists.

### Fallback: CLAUDE.md

If no standard marker file matches, read the project's `CLAUDE.md` (if it exists) and
scan for documented build/check/test commands. Look for sections like "Key Commands",
"Development", "Build", or similar headings. Common patterns to extract:

- `dots test`, `dots sync` — custom project scripts
- `make <target>`, `just <recipe>` — documented but non-standard locations
- `./scripts/build.sh` — custom build scripts

If CLAUDE.md documents a check/test/build command, use it and note the source:
```
✓ Build passed (dots test, from CLAUDE.md) — clean
```

If neither marker files nor CLAUDE.md yield a build command, report clearly and stop.

## Step 2: Run the Command

Run from the **project root directory** — `cd` into it first.

```bash
cd <project-root>
<build-command> 2>&1 | cat
echo "EXIT_CODE:$?"
```

The `| cat` forces non-interactive mode and strips most ANSI color codes. For stubborn
tools, pipe through `sed 's/\x1b\[[0-9;]*m//g'` as well.

**Sandbox note**: This skill runs as a forked subagent inheriting the parent's sandbox.
If the target project is outside the parent's sandbox write allowlist, build tools that
write artifacts (cargo → `target/`, npm → `node_modules/`) will fail. When this happens,
report it clearly — the caller should invoke `/make` from within the target project.

## Step 3: Parse the Output

Extract errors and warnings into structured format. Match against these known patterns:

| Tool | Error Pattern | Example |
|---|---|---|
| Rust/cargo | `error[EXXXX]: msg` + ` --> file:line:col` | `error[E0425]: cannot find value` |
| TypeScript/tsc | `file(line,col): error TSXXXX: msg` | `src/app.ts(12,5): error TS2304` |
| Go | `file:line:col: msg` | `main.go:15:2: undefined: foo` |
| Python/mypy | `file:line: error: msg [code]` | `app.py:10: error: incompatible type [arg-type]` |
| ESLint | `file:line:col  error  msg  rule` | `src/app.js:5:3  error  ...` |
| GCC/Clang | `file:line:col: error: msg` | `main.c:10:5: error: undeclared` |
| Java/javac | `file:line: error: msg` | `App.java:15: error: cannot find` |
| Ruff | `file:line:col: EXXXX msg` | `app.py:3:1: F401 unused import` |
| Prettier | `[error] file: msg` | `[error] src/app.ts: SyntaxError` |
| Pre-commit | Various — parse each hook's output separately | Hook failures contain tool output |

**Parsing rules:**
- Extract: file path, line number, column (if available), error code (if available), message
- Truncate messages at 120 characters
- Distinguish errors from warnings (most tools use the word explicitly)
- For unknown output formats, look for lines containing `error` or `warning` near file paths

**Multi-step commands** (like `make check` running lock + pre-commit + mypy):
- Track each step's pass/fail separately
- If a step is skipped (sandbox, missing tool), report it as skipped — not as an error
- Roll up to a single structured result at the end

## Step 4: Return Structured Results

Use EXACTLY these templates. Do not improvise or add commentary.

### On success (exit code 0, no errors):

```
✓ Build passed (<tool>) — clean
```

Or with warnings:
```
✓ Build passed (<tool>) — 0 errors, <N> warnings

Warnings (<N>):
  <file>:<line>:<col> — <message> [<code>]
```

### On failure (exit code non-zero or errors found):

```
✗ Build failed (<tool>) — <N> errors, <N> warnings

Errors (<N>):
  <file>:<line>:<col> — <message> [<code>]
  <file>:<line>:<col> — <message> [<code>]

Warnings (<N>):
  <file>:<line>:<col> — <message> [<code>]
```

### On no build system detected:

```
⚠ No build system detected

  Checked: Justfile, Cargo.toml, package.json, go.mod, pyproject.toml, Makefile, CMakeLists.txt
  CLAUDE.md: <not found | no build commands documented>
```

### On tool not found:

```
✗ Build tool not available — <tool> is not installed
  Detected: <marker file>
  Expected command: <command>
```

### On sandbox restriction:

```
⚠ Sandbox blocked <tool> — needs write access to <path>
  Run /make from within the target project instead.
```

### With skipped steps (multi-step builds):

```
✗ Build failed (make check) — 1 error, 0 warnings

Errors (1):
  src/optimizer.py:26:1 — Cannot find module "optuna" [import-not-found]

Skipped:
  uv lock --locked (sandbox restriction)
  pre-commit run -a (sandbox restriction)
```

### Output caps:
- Max 50 errors shown. If more: show first 30, then `... and <N> more errors`
- Max 20 warnings shown. If more: show first 10, then `... and <N> more warnings`
- Group by file when there are 10+ issues — makes it scannable
- Always include the total count in the header even if truncated

## Subcommands (test, lint, fmt, clean)

When invoked with a subcommand, read `references/subcommands.md` for the
detection rules, command mappings, and output templates for that subcommand.

## What You Don't Do

- Fix build errors — report them, let the caller decide
- Install missing tools or dependencies
- Modify source code
- Run commands outside the project root

## Gotchas

- ANSI color stripping is imperfect — some escape sequences leak through to the report
- Sandbox restrictions may prevent writing to build artifact dirs (`target/`, `node_modules/.cache/`)
- Multi-step commands may partially succeed — report each step's status individually
- Justfile recipe names are case-sensitive — `just Check` ≠ `just check`

## Rules

- ALWAYS parse output into the structured file:line:col format before returning
- ALWAYS include file:line:col for every error — the caller navigates by these
- ALWAYS strip progress bars, download logs, and compilation unit lists before returning
- Return facts only — no commentary, suggestions, or fix recommendations
- Strip ANSI color codes before parsing
- If the build produces no output and exits 0, that's a clean pass
- If you can't determine the build system, say so clearly — use only detected build tools
- ALWAYS capture exit code — some tools report warnings on stdout but exit 0
- Use the EXACT output templates above — do not improvise formatting
