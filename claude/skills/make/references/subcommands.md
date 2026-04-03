# Subcommand Reference

Read this file only when `/make` is invoked with a subcommand (test, lint, fmt, clean).
Use the same detection order as the main build system detection (marker files → CLAUDE.md).

## test

Common test commands:

| Tool | Test Command |
|---|---|
| just | `just test 2>&1` |
| cargo | `cargo test 2>&1` |
| npm | `npm test 2>&1` |
| go | `go test ./... 2>&1` |
| uv/python | `uv run pytest --tb=short -q 2>&1` |
| make | `make test 2>&1` |
| CLAUDE.md | Whatever test command is documented |

Parse output into pass/fail/skip counts plus failure details:

```
## Test Results
- **Passed**: <N> | **Failed**: <N> | **Skipped**: <N>
- **Command**: `<command>`

### Failures
<file>:<line> — <test name>: <assertion detail>
```

Cap failure detail at 10 lines per test, 5 detailed + rest summarized if >10 failures.

## lint

Run the project's linter (stricter than check — includes style, complexity, correctness warnings):

| Tool | Lint Command |
|---|---|
| just | `just lint 2>&1` (if recipe exists, else fall back to tool-specific) |
| cargo/clippy | `cargo clippy --message-format=short 2>&1` |
| npm/eslint | `npx eslint . 2>&1` |
| go/golangci-lint | `golangci-lint run 2>&1` |
| uv/ruff | `uv run ruff check . 2>&1` |
| make | `make lint 2>&1` (if target exists) |

Parse output using the same error/warning format as Step 3 in the main skill.

## fmt

Detect and run the formatter in check mode (no writes):

| Tool | Fmt Check Command |
|---|---|
| cargo/rustfmt | `cargo fmt --check 2>&1` |
| prettier | `npx prettier --check . 2>&1` |
| ruff | `uv run ruff format --check . 2>&1` |
| black | `uv run black --check . 2>&1` |
| gofmt | `gofmt -l . 2>&1` |
| just | `just fmt --check 2>&1` (if recipe exists) |

```
✗ Format check failed — <N> files need formatting

  src/lib.rs
  src/main.rs
  tests/integration.rs
```

Or on success: `✓ Format check passed — all files formatted`

## clean

| Tool | Clean Command |
|---|---|
| cargo | `cargo clean` |
| npm | `rm -rf node_modules dist build` |
| go | `go clean` |
| make/cmake | `make clean` |
| just | `just clean` (if recipe exists) |
| gradle | `./gradlew clean` |
| maven | `mvn clean` |

Return: `✓ Clean complete (<tool>)` or report if no clean target exists.
