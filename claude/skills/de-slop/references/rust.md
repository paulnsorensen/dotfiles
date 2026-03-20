# Rust Anti-Patterns

## 1. Excessive `.clone()` to silence the borrow checker

LLMs reach for `.clone()` as a universal fix for ownership errors.

**Fix:**
- Use borrowing (`&` and `&mut`) instead
- Take `&str` instead of `String` in function parameters
- Use `.as_ref()` on `Option`/`Result` instead of cloning to unwrap
- Rule: `.clone()` is banned unless you can explain why you need owned data

```rust
// SLOP
fn greet(name: String) { println!("Hello, {name}"); }
let msg = my_string.clone();
greet(msg);

// CLEAN
fn greet(name: &str) { println!("Hello, {name}"); }
greet(&my_string);
```

## 2. `.unwrap()` everywhere

Creates runtime panics scattered throughout the codebase.

**Fix:**
- Use `?` operator for error propagation
- Use `anyhow` or `thiserror` for structured errors
- Use `if let Some(x)` or `match` for `Option` types
- `.unwrap()` only for compile-time guarantees (hardcoded regex, constants)

```rust
// SLOP
let file = File::open("config.toml").unwrap();
let config: Config = toml::from_str(&contents).unwrap();

// CLEAN
let file = File::open("config.toml")?;
let config: Config = toml::from_str(&contents)?;
```

## 3. Treating everything as `String`

Losing type safety and adding unnecessary allocations.

**Fix:**
- Accept `&str` or `impl AsRef<str>` in function parameters
- Use `Cow<'_, str>` when sometimes owned, sometimes borrowed
- Create newtypes for domain concepts: `struct UserId(String)`

```rust
// SLOP
fn find_user(id: String, name: String) -> String { ... }

// CLEAN
fn find_user(id: &UserId, name: &str) -> Result<User> { ... }
```

## 4. Index-based loops instead of iterators

C-style `for i in 0..vec.len()` misses safety and optimization.

**Fix:**
- Use `.iter()`, `.map()`, `.filter()`, `.enumerate()`, `.collect()`
- Use slice patterns: `match vec.as_slice() { [first, ..] => ... }`

```rust
// SLOP
for i in 0..items.len() {
    process(i, &items[i]);
}

// CLEAN
for (i, item) in items.iter().enumerate() {
    process(i, item);
}
```

## 5. Fighting lifetimes with `Rc<RefCell<T>>`

When ownership gets complex, AI reaches for interior mutability or `unsafe`.

**Fix:**
- Reduce borrow lifetimes so they don't overlap
- Design structs to own their data
- Pass short-lived borrows as method parameters
- Restructure to avoid holding long-lived references

## 6. Weak assertions — the #1 AI test smell

`assert!(result.is_ok())` and `assert!(result.is_err())` swallow the actual
error/value on failure, printing only `false`.

**Fix:**
- Propagate with `.expect("context")` or `?` to see the real error
- Check actual values, not just existence
- For errors, verify the specific variant with `matches!` or check the message
- Every `assert_eq!`/`assert!` with non-obvious operands needs a failure message

```rust
// SLOP
assert!(result.is_ok());
assert!(result.is_err());
assert_eq!(count, 3);  // no context on failure

// CLEAN — propagate the real error
let value = result.expect("scan_worktree should succeed");
assert_eq!(value.label, "Ready");

// CLEAN — check specific error variant
assert!(matches!(result, Err(MyError::NotFound { .. })));
// or check the message
let err = result.unwrap_err();
assert!(err.to_string().contains("not found"), "expected NotFound, got: {err}");

// CLEAN — failure message for non-obvious operands
assert_eq!(count, 3, "expected 3 active workers after spawn");
```

## 7. `is_none()` / `is_some()` without value context

`assert!(x.is_none())` prints `assertion failed: false`. `assert_eq!` shows what was actually there.

**Fix:**
- Use `assert_eq!(x, None)` for better failure messages
- For `is_some()`, extract and check the inner value

```rust
// SLOP
assert!(x.is_none());
assert!(ping["result"]["host_type"].as_str().is_some());

// CLEAN
assert_eq!(x, None);
assert_eq!(ping["result"]["host_type"].as_str(), Some("daemon"));
```

## 8. Async timing slop

Raw `tokio::time::sleep` before assertions is fragile — passes on fast machines, flakes in CI.

**Fix:**
- Use a `wait_until_async` polling pattern with timeout
- Sleep-then-assert is only acceptable for testing actual timing behavior

```rust
// SLOP
tokio::time::sleep(Duration::from_millis(500)).await;
assert_eq!(state.status(), "ready");

// CLEAN — poll with timeout
wait_until_async(Duration::from_secs(2), || async {
    state.status() == "ready"
}).await.expect("status should reach ready");
```

## 9. `#[should_panic]` without `expected`

A bare `#[should_panic]` passes on *any* panic — including unrelated ones from
refactoring. Always pin the expected message.

**Fix:**
- Add `expected = "substring"` to match the intended panic message

```rust
// SLOP
#[test]
#[should_panic]
fn rejects_empty_input() {
    parse("");
}

// CLEAN
#[test]
#[should_panic(expected = "input must not be empty")]
fn rejects_empty_input() {
    parse("");
}
```

## 10. No-crash-is-success tests

Tests with zero assertions only prove the code doesn't panic — not that it works.

**Fix:**
- Add assertions on return values or side effects
- If intentionally testing "no panic", add an explicit comment documenting why

```rust
// SLOP
#[test]
fn stamp_activity_nonexistent_is_noop() {
    tracker.stamp_activity("ghost-id");
}

// CLEAN — document the intent
#[test]
fn stamp_activity_nonexistent_is_noop() {
    // No assertion needed: verifying no panic on missing ID
    tracker.stamp_activity("ghost-id");
}
```

## 11. Hallucinated APIs and deprecated syntax

AI generates functions that don't exist or uses outdated API patterns
(e.g., `clap` `App::new` instead of derive macros).

**Fix:**
- Run `cargo check` immediately after generating code
- Pin specific crate versions
- Use Clippy: `cargo clippy -- -W clippy::all`
- When in doubt, check docs with Context7
