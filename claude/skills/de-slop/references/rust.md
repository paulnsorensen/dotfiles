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

## 6. Hallucinated APIs and deprecated syntax

AI generates functions that don't exist or uses outdated API patterns
(e.g., `clap` `App::new` instead of derive macros).

**Fix:**
- Run `cargo check` immediately after generating code
- Pin specific crate versions
- Use Clippy: `cargo clippy -- -W clippy::all`
- When in doubt, check docs with Context7
