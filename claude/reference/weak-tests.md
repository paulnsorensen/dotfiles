# Weak Test Patterns

Systematically predictable patterns that make tests pass without proving anything. These apply across all languages — language-specific examples are provided where patterns differ.

## 1. No Assertions (Smoke-Only Tests)

Test calls the function but asserts nothing. Proves the code doesn't panic, not that it works.

```rust
// WEAK
#[test]
fn test_parse_config() {
    let _ = parse_config("valid.toml");
}

// STRONG
#[test]
fn test_parse_config() {
    let config = parse_config("valid.toml").unwrap();
    assert_eq!(config.database.port, 5432);
    assert_eq!(config.database.name, "mydb");
}
```

```typescript
// WEAK
test("parse config", () => {
  parseConfig("valid.toml");
});

// STRONG
test("parse config", () => {
  const config = parseConfig("valid.toml");
  expect(config.database.port).toBe(5432);
});
```

**Rule:** Every test must assert on a specific, meaningful output value.

## 2. Assert Only Ok/Some/No-Error

Checks that the result type is correct but ignores the actual value. Passes for any successful return.

```rust
// WEAK
#[test]
fn test_find_user() {
    let result = find_user("alice");
    assert!(result.is_ok());
}

// STRONG
#[test]
fn test_find_user() {
    let user = find_user("alice").unwrap();
    assert_eq!(user.name, "alice");
    assert_eq!(user.role, Role::Admin);
}
```

**Rule:** Unwrap the success value and assert on its contents. `is_ok()` / `is_some()` alone is only acceptable when the test name explicitly says "should succeed" and a companion test covers the value.

## 3. Tautological Assertions

Assertion that cannot fail because it compares a value to itself or to a value derived from the same source.

```rust
// WEAK — always passes
let x = compute();
assert_eq!(x, x);

// WEAK — asserts the setup, not the behavior
let input = vec![1, 2, 3];
let result = identity(input.clone());
assert_eq!(result, input);  // only if identity() is the function under test

// WEAK — hardcoded echo
let name = "alice";
let greeting = format!("hello, {name}");
assert_eq!(greeting, "hello, alice");  // tests `format!`, not your code
```

**Rule:** The expected value must be an independent specification of correctness, not derived from the code under test.

## 4. Mirror Implementation

Test re-implements the production logic and compares. If the code has a bug, the test has the same bug.

```rust
// WEAK — mirrors the implementation
#[test]
fn test_discount() {
    let price = 100.0;
    let discount = 0.15;
    let expected = price * (1.0 - discount);  // same math as production code
    assert_eq!(calculate_discount(price, discount), expected);
}

// STRONG — uses a known, independently derived expected value
#[test]
fn test_discount() {
    assert_eq!(calculate_discount(100.0, 0.15), 85.0);
}
```

**Rule:** Expected values should be literal constants or independently computed. Never copy-paste the production formula into the test.

## 5. Mock Echo

Mock returns X, test asserts the result is X. Tests that the mock works, not that the code handles the mock's output correctly.

```rust
// WEAK — mock returns exactly what we assert
let mock_repo = MockRepo::new();
mock_repo.expect_find().returning(|_| Ok(User { name: "alice".into() }));
let service = UserService::new(mock_repo);
let user = service.get_user("alice").unwrap();
assert_eq!(user.name, "alice");  // the mock said "alice", so of course it's "alice"

// STRONG — assert on transformation/behavior, not the mock's raw output
let mock_repo = MockRepo::new();
mock_repo.expect_find().returning(|_| Ok(User { name: "alice".into(), role: Role::User }));
let service = UserService::new(mock_repo);
let response = service.get_user_profile("alice").unwrap();
assert_eq!(response.display_name, "Alice");  // tests capitalization logic
assert!(response.permissions.contains(&Permission::Read));  // tests role mapping
```

**Rule:** If the test asserts on a value that passes through untransformed from a mock, the test proves nothing. Assert on derived/transformed outputs.

## 6. Happy Path Only

All tests use valid inputs. No error paths, edge cases, or boundary conditions are tested.

```rust
// WEAK — only tests the golden path
#[test]
fn test_parse_age() {
    assert_eq!(parse_age("25"), Ok(25));
}

// STRONG — covers boundaries and errors
#[test]
fn test_parse_age_valid() {
    assert_eq!(parse_age("0"), Ok(0));
    assert_eq!(parse_age("150"), Ok(150));
}

#[test]
fn test_parse_age_invalid() {
    assert!(parse_age("-1").is_err());
    assert!(parse_age("151").is_err());
    assert!(parse_age("").is_err());
    assert!(parse_age("abc").is_err());
}
```

**Rule:** For every happy-path test, there should be at least one test for invalid input, boundary values, or error conditions.

## 7. Assert Only Collection Length

Checks the count but not the contents. Right number of wrong items still passes.

```rust
// WEAK
#[test]
fn test_search() {
    let results = search("rust");
    assert_eq!(results.len(), 3);
}

// STRONG
#[test]
fn test_search() {
    let results = search("rust");
    assert_eq!(results.len(), 3);
    assert!(results.iter().any(|r| r.title == "The Rust Book"));
    assert!(results.iter().all(|r| r.title.to_lowercase().contains("rust")));
}
```

**Rule:** `.len()` assertions are a useful sanity check but must be paired with content assertions.

## 8. Asserting on Debug/Display Output

Tests stringify the result and compare to a hardcoded string. Brittle (formatting changes break the test) and hides what's actually being verified.

```rust
// WEAK
#[test]
fn test_user() {
    let user = User::new("alice", Role::Admin);
    assert_eq!(format!("{user:?}"), "User { name: \"alice\", role: Admin }");
}

// STRONG
#[test]
fn test_user() {
    let user = User::new("alice", Role::Admin);
    assert_eq!(user.name, "alice");
    assert_eq!(user.role, Role::Admin);
}
```

**Rule:** Assert on structured fields, not string representations. Exception: tests specifically verifying Display/Debug impl formatting.

## 9. Tests That Never Fail

Test is structured so that the assertion is unreachable or always true.

```rust
// WEAK — assertion is inside a branch that may not execute
#[test]
fn test_find() {
    if let Some(user) = find_user("alice") {
        assert_eq!(user.name, "alice");
    }
    // silently passes if find_user returns None
}

// STRONG
#[test]
fn test_find() {
    let user = find_user("alice").expect("should find alice");
    assert_eq!(user.name, "alice");
}
```

**Rule:** Assertions must be on the unconditional path. Use `.unwrap()` / `.expect()` in tests to force failure on unexpected None/Err.

## Summary Table

| # | Pattern | Symptom | Fix |
|---|---------|---------|-----|
| 1 | No assertions | `let _ = foo()` | Assert on specific output values |
| 2 | Assert only Ok/Some | `assert!(r.is_ok())` | Unwrap and assert on contents |
| 3 | Tautological | `assert_eq!(x, x)` | Use independent expected values |
| 4 | Mirror implementation | Test copies production formula | Use literal expected constants |
| 5 | Mock echo | Assert mock's own return value | Assert on transformed/derived output |
| 6 | Happy path only | No error/edge tests | Add boundary + invalid input tests |
| 7 | Length-only | `assert_eq!(v.len(), 3)` | Add content assertions |
| 8 | Debug/Display string | `format!("{:?}")` comparison | Assert on structured fields |
| 9 | Never fails | Assertion inside conditional | Put assertions on unconditional path |
