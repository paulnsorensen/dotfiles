---
name: test-sandbox
model: haiku
context: fork
allowed-tools: Read, Write, Bash(python3:*), Bash(uv:*), Bash(pytest:*), Bash(ls:*), Bash(rm:*)
description: >
  Run Python test code in an isolated sandbox without polluting the main context.
  Writes test files to .claude/testing/ (gitignored), runs via sub-agent, and
  reports only pass/fail counts and assertion details. Use when you want to quickly
  verify code without writing inline python3 -c scripts. Also supports --sweep to
  clean stale test files. Use when the user says "run a quick test", "verify this
  works", "sanity check", "test this snippet", or invokes /test-sandbox.
---

# /test-sandbox — Isolated Test Sandboxing

Run Python test code in an isolated, sandboxed environment without polluting the main context. Ideal for quick assertions and verification during development.

## Usage

### Quick Test

```bash
/test-sandbox "assert 1 + 1 == 2"
```

### Test with Imports

```bash
/test-sandbox "from src.orders import process_order; assert process_order({}) == expected"
```

### Test from File

```bash
/test-sandbox --file tests/test_edge_cases.py
```

### Sweep Stale Tests

```bash
/test-sandbox --sweep
```

## How It Works

1. **Writes test file** to `.claude/testing/test_<hash>.py` (isolated from repo)
2. **Runs test** via sub-agent: `uv run pytest .claude/testing/test_<hash>.py --tb=short`
3. **Reports concisely**: ✓/✗ pass count, assertions run, findings >= 50 confidence only
4. **Cleans up** the test file (optional, configurable per session)

The skill delegates to sub-agents to keep your main context clean — you only see the results, not the verbose test output or implementation details.

## Examples

### Example 1: Quick Assertion

```
> /test-sandbox "assert 'hello'.upper() == 'HELLO'"

✓ Test passed: 1 assertion ran, all passed
Wrote: .claude/testing/test_abc123.py
```

### Example 2: Module Test

```
> /test-sandbox "from src.auth import verify_token; assert verify_token('valid') is True; assert verify_token('bad') is False"

✓ Test passed: 2 assertions ran, all passed
```

### Example 3: Test Failure

```
> /test-sandbox "assert 1 + 1 == 3"

✗ Test failed: AssertionError
  Expected: 3
  Actual: 2
File: .claude/testing/test_xyz789.py (not cleaned up for inspection)
```

### Example 4: Sweep

```
> /test-sandbox --sweep

Cleaned 7 stale test files (> 24 hours old)
`.claude/testing/` now contains 2 recent tests
```

## Flags

| Flag | Behavior |
|------|----------|
| `--sweep` | Delete test files older than 24 hours. Does not run tests. |
| `--file <path>` | Run tests from an existing file instead of inline code. |
| `--keep` | Don't clean up test file after run (for inspection). |

## Gitignore Integration

On first use, `/test-sandbox` automatically adds `.claude/testing/` to `.gitignore` if not already present. No manual action needed.

## Quality

- **Real test runner**: Uses your project's `uv run pytest`, not a mock runner. Respects venv, fixtures, conftest.
- **Confidence scoring**: Only surfaces findings scored >= 50 (high-confidence issues).
- **Context discipline**: Sub-agent reports summarized to ~2K max. Full details available in `$TMPDIR` if needed.
- **Fail-safe cleanup**: Stale test files are swept automatically (24-hour age threshold).

## When to Use This

**Good for**:

- Quick verifications during development
- Testing a new function before committing
- Edge case exploration
- Validation of refactoring

**Not ideal for**:

- Long-term test suites (use `tests/` directory instead)
- Collaborative tests (tests belong in repo, not `.claude/testing/`)
- Fixtures or setup that needs persistence (use `conftest.py`)

## Tips & Tricks

### Capture Output

```
/test-sandbox "from src.module import fn; result = fn(); assert result > 0; print(f'Result: {result}')"
```

### Multiple Assertions

Separate with semicolons:

```
/test-sandbox "from mymodule import Cls; c = Cls(); assert c.x == 1; assert c.y == 2; assert c.z == 3"
```

### Test a Refactor

```
/test-sandbox --file src/old_module.py  # Run old module's internal test suite
```

### Debug a Failure

```
/test-sandbox --keep "assert my_fn() == expected"  # Don't delete file after failure
cat .claude/testing/test_*.py  # Inspect the generated test
```

## Implementation

- **Skill**: Routes test code to sub-agents (roquefort-wrecker for TDD work)
- **Sub-agents**: Spawn in parallel for independence, write test files, run tests, score findings
- **Output**: Only pass/fail counts + findings >= 50. Verbose output trapped in sub-agent context.
- **Cleanup**: Automatic after run (unless `--keep` flag used)
- **Gitignore**: Idempotent (safe to run multiple times)

See `claude/CLAUDE.md` for sub-agent delegation patterns and context discipline rules.

## Gotchas

- Module imports fail if PYTHONPATH doesn't include project root — prefix with `PYTHONPATH=.`
- conftest.py fixtures from `tests/` are not available in `.claude/testing/` — copy needed fixtures
- `uv` must be installed — fall back to `python -m pytest` if unavailable
- Test files in `.claude/testing/` are gitignored but accumulate — use `--sweep` periodically
