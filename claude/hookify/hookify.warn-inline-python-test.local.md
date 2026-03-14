---
name: warn-inline-python-test
enabled: true
event: file
conditions:
  - field: new_text
    operator: regex_match
    pattern: (?:python3?\s+-c\s+['"][^'"]*(?:import|assert|print\s*\()|cat\s+<<)
action: warn
---

**Inline test code detected in implementation file.**

This suggests testing via `python3 -c "import X; assert ..."` pattern, which:

- **Bypasses venv isolation** — no project dependencies, no fixture setup
- **Ignores pytest configuration** — conftest, markers, plugins don't apply
- **Leaves no artifact** — test is invisible to CI, history, and other team members
- **Not reusable** — one-off verification, not part of your test suite

This violates the **Real-World Models** principle: tests are first-class code artifacts that describe your system's contract. They belong in your test suite, not buried in shell commands.

**Better approaches**:

1. **Use the /test-sandbox skill** (quick verification):
   ```
   /test-sandbox "assert my_module.fn() == expected"
   ```
   Writes to `.claude/testing/`, runs in isolation, reports results.

2. **Write a proper test file** (preferred):
   ```bash
   uv run pytest tests/test_feature.py --tb=short -v
   ```
   Reusable, discoverable, CI-integrated.

3. **Use uv run for quick checks**:
   ```bash
   uv run python -c "from src.module import fn; print(fn())"
   ```
   But reserve this for investigation only, not assertions.

Commit your test code to the repository — it's as important as the implementation. The test suite is your system's specification.
