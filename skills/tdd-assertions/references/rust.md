# Rust Weak Assertions

## 1. `is_ok()` / `is_some()` without value check

AI asserts the `Result`/`Option` variant but never inspects the value inside.

```rust
// WEAK
assert!(result.is_ok());
assert!(result.is_some());
assert!(!vec.is_empty());

// STRONG
assert_eq!(result.unwrap(), 42);
assert_eq!(result.unwrap(), ExpectedStruct { field: "value" });
assert_eq!(vec, vec!["a", "b", "c"]);
```

## 2. `is_err()` without variant/message check

Any error passes — wrong error type, wrong message, doesn't matter.

```rust
// WEAK
assert!(result.is_err());

// STRONG — specific variant
assert!(matches!(result, Err(MyError::NotFound(_))));

// STRONG — variant + content (no external crate needed)
assert!(matches!(result, Err(MyError::NotFound(msg)) if msg.contains("id=42")));

// STRONG — with assert_eq on error
let err = result.unwrap_err();
assert_eq!(err.kind(), ErrorKind::NotFound);
```

## 3. `#[should_panic]` without `expected`

Any panic passes the test. A refactor that panics at a different point
still passes.

```rust
// WEAK
#[should_panic]
fn test_overflow() { ... }

// STRONG
#[should_panic(expected = "index out of bounds")]
fn test_overflow() { ... }
```

## 4. Debug format assertions

Testing `Debug` string representation instead of structural equality.

```rust
// WEAK — format changes break the test, not behavior changes
assert!(format!("{:?}", x).contains("Foo"));
assert_eq!(format!("{}", result), "expected string");

// STRONG — implement PartialEq and compare structurally
assert_eq!(x, Foo { field: "value" });

// If you need string output, test Display explicitly
assert_eq!(result.to_string(), "expected string");
```

## 5. `unwrap()` in tests without `expect()`

When the test fails, you get "called unwrap on None" with no context.

```rust
// WEAK — opaque failure message
let user = repo.find(42).unwrap();

// STRONG — failure tells you what went wrong
let user = repo.find(42).expect("user 42 should exist in test fixture");
```

## 6. Boolean `assert!` where `assert_eq!` applies

`assert!` gives no context on failure. `assert_eq!` shows both values.

```rust
// WEAK — failure says "assertion failed"
assert!(result == 42);
assert!(items.len() == 3);

// STRONG — failure says "left: 41, right: 42"
assert_eq!(result, 42);
assert_eq!(items.len(), 3);
```

## 7. Floating-point `assert_eq!` on computed values

Direct equality fails for floating-point arithmetic due to rounding.

```rust
// WEAK — may fail due to float rounding
assert_eq!(compute_ratio(1.0, 3.0), 0.333333);

// STRONG — use approx crate or epsilon comparison
assert!((compute_ratio(1.0, 3.0) - 0.333333).abs() < 1e-6);
// Or with approx crate:
assert_relative_eq!(compute_ratio(1.0, 3.0), 0.333333, epsilon = 1e-6);
```

Note: the reverse is also a smell — using epsilon comparison when the math
is exact (integer arithmetic, simple multiplication). Use `assert_eq!` for
deterministic values.
