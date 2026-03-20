---
name: tdd-assertions
model: sonnet
description: >
  Detect and fix weak test assertions that AI generates across Rust, Python,
  TypeScript, Go, and Shell. Use this skill whenever you write or review tests,
  when the user says "strengthen assertions", "fix weak tests", or during
  /wreck, /fromage, and /simplify flows. Also use as a mental checklist before
  committing test code — AI assistants systematically produce assertions that
  pass when the code is broken, which is the cardinal sin of TDD.
  Trigger proactively on test generation and test review.
allowed-tools: Read, Edit, Grep, Glob, Bash(rg:*)
---

# tdd-assertions

Fix weak test assertions that pass when the code is broken.

AI coding assistants optimize for test coverage metrics, not test utility.
The result is assertions that *look* thorough but can't catch regressions:
existence checks instead of value equality, catch-all error types, length
checks without content inspection, and mock verification without arguments.

A test that can't fail when behavior breaks isn't a test — it's a liability.

## When to apply

- **After writing tests** — review assertions before presenting them
- **During /wreck** — the adversarial tester should produce strong assertions
- **In /fromage** — part of the Press agent's quality gate
- **Pre-commit** — hook reminds you to check assertion strength
- **On demand** — user says "strengthen assertions", "fix weak tests", etc.

## Protocol

1. **Detect test framework** from imports/syntax (pytest, jest/vitest, `#[test]`, testing, bats)
2. **Read the relevant reference** from `references/` (only the languages present)
3. **Scan for weak patterns** — both cross-language and framework-specific
4. **Fix directly** — replace weak assertions with strong ones
5. **Explain briefly** — one line per fix, what was weak and what it checks now

## Cross-Framework Patterns

These apply to every language. They're the most common AI assertion failures.

### 1. Existence check instead of value equality

The #1 AI testing sin. Asserts something exists without verifying it's correct.

```
WEAK: assert result is not None
WEAK: expect(result).toBeDefined()
WEAK: assert!(result.is_some())

STRONG: assert result == expected_value
STRONG: expect(result).toEqual({ id: 1, name: "Alice" })
STRONG: assert_eq!(result.unwrap(), expected)
```

**Fix:** Always assert the specific value you expect, not just that a value exists.

### 2. Length check without content inspection

Verifies the container has items but not what those items are.

```
WEAK: assert len(results) == 1
WEAK: expect(items).toHaveLength(3)
WEAK: assert_eq!(vec.len(), 2)

STRONG: assert results[0].name == "Alice"
STRONG: expect(items).toEqual([...expected])
STRONG: assert_eq!(vec, vec!["a", "b"])
```

**Fix:** Check content first. Length-only assertions are OK as a *final* confirmation
after content checks, never as the sole assertion.

### 3. Catch-all error assertions

Verifies an error occurred without checking it's the *right* error.

```
WEAK: with pytest.raises(Exception):
WEAK: expect(() => fn()).toThrow()
WEAK: assert!(result.is_err())
WEAK: assert.Error(t, err)

STRONG: with pytest.raises(ValueError, match=r"must be positive"):
STRONG: expect(() => fn()).toThrow(ValidationError)
STRONG: assert!(matches!(result, Err(MyError::NotFound(_))))
STRONG: require.ErrorAs(t, err, &notFoundErr)
```

**Fix:** Assert the specific error type AND message/content.

### 4. No-crash-as-success

Test only asserts the function didn't throw, with no behavioral check.

```
WEAK: run my_command; assert_success
WEAK: result, err := fn(); require.NoError(t, err)  // nothing follows
WEAK: expect(() => fn()).not.toThrow()  // sole assertion

STRONG: run my_command; [[ "$output" == "expected" ]]
STRONG: require.NoError(t, err); assert.Equal(t, expected, result)
STRONG: expect(fn()).toEqual(expected)
```

**Fix:** Every test needs a positive behavioral assertion. "Didn't crash" is necessary
but never sufficient.

### 5. Mock verification without arguments

Verifies a mock was called but not *how* it was called.

```
WEAK: mock_fn.assert_called()
WEAK: expect(mockFn).toHaveBeenCalled()
WEAK: mock.AssertCalled(t, "Send")

STRONG: mock_fn.assert_called_once_with(user_id=42, role="admin")
STRONG: expect(mockFn).toHaveBeenCalledWith({ to: "alice@example.com" })
STRONG: mock.AssertCalled(t, "Send", expected_msg)
```

**Fix:** Always verify mock call arguments. A mock called with wrong arguments
is a test that passes while the code is broken.

### 6. Testing the mock, not the code

Asserts that a mock returns what you told it to return — tautological.

```
WEAK:
  mock = Mock(return_value=42)
  assert mock() == 42  # You just tested Mock.__call__

WEAK:
  const mock = jest.fn().mockReturnValue(42);
  expect(mock()).toBe(42);  // Tests jest.fn, not your code
```

**Fix:** The assertion should check the *system under test* which *uses* the mock,
not the mock itself.

### 7. Boolean coercion assertions

Uses truthiness where a value check is possible and more precise.

```
WEAK: assert bool(result)
WEAK: expect(!!result).toBe(true)
WEAK: assert!(some_function())

STRONG: assert result == expected_value
STRONG: expect(result).toEqual(expected)
STRONG: assert_eq!(some_function(), expected)
```

**Fix:** If you know what the value should be, assert that. Truthiness only
when the contract genuinely is "any truthy value."

### 8. Tautological assertions

Assertions that literally cannot fail. A test that always passes tests nothing.

```
WEAK: assert True
WEAK: expect(1).toBe(1)
WEAK: assert_eq!(true, true)

WEAK: # Status catch-all
[[ $status -eq 0 || $status -eq 1 ]]  # anything-passes guard
```

**Fix:** Delete tautological assertions. If the test needs a placeholder, mark it
as `@pytest.mark.skip` / `it.todo()` / `#[ignore]` instead.

### 9. Approximate equality when exact is possible

Uses fuzzy matching when the result is deterministic.

```
WEAK: assert abs(result - 100) < 1        # result IS exactly 100
WEAK: expect(result).toBeCloseTo(100)      # when result is integer math
WEAK: assert!((result - 1.0).abs() < f64::EPSILON)  # when input is exact

STRONG: assert result == 100
STRONG: expect(result).toBe(100)
STRONG: assert_eq!(result, 1.0)
```

**Fix:** Use approximate equality only for floating-point arithmetic that
genuinely introduces rounding. Integer math, string operations, and
deterministic calculations should use exact equality.

## Language References

Read these only for test frameworks present in the code being reviewed:

| Language | Reference |
|----------|-----------|
| Rust | `references/rust.md` |
| Python (pytest) | `references/python.md` |
| TypeScript/JavaScript (jest/vitest) | `references/typescript.md` |
| Go (testing/testify) | `references/go.md` |
| Shell/Bash (bats) | `references/shell.md` |

## Output format

When fixing assertions, explain each change concisely:

```
Strengthened 4 assertions:
- assert result is not None → assert result == User(id=1, name="Alice")
- pytest.raises(Exception) → pytest.raises(ValueError, match="must be positive")
- mock.assert_called() → mock.assert_called_once_with(user_id=42)
- Deleted tautological assert True
```

Don't over-explain. The stronger assertion speaks for itself.

## What You Don't Do

- Write new tests from scratch — use /wreck for adversarial test generation
- Fix implementation code — only strengthen the assertions
- Add test infrastructure (fixtures, conftest, helpers) — focus on assertion quality
- Review non-test code — use /de-slop for production code anti-patterns

## Gotchas

- `is not None` is correct when the contract genuinely is "returns any value, not None"
- `toBeCloseTo` / `assertAlmostEqual` is correct for floating-point arithmetic — not weak
- Mock argument checking can be excessive for fire-and-forget calls — use judgment
- Catch-all `except Exception` is valid in top-level error boundaries — only flag in inner code
