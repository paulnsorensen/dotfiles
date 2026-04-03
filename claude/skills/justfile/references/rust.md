# Rust Justfile Recipes

## Template

```just
set dotenv-load := true

default: check

# Run all checks (CI equivalent)
check: fmt-check clippy test

# Format code
fmt:
    cargo fmt --all

# Check formatting without modifying
fmt-check:
    cargo fmt --all -- --check

# Run clippy lints
clippy:
    cargo clippy --all-targets --all-features -- -D warnings

# Run tests
test *args:
    cargo test {{args}}

# Run tests with nextest (if installed)
test-fast *args:
    cargo nextest run {{args}}

# Build debug
build:
    cargo build

# Build release
build-release:
    cargo build --release

# Run the binary
run *args:
    cargo run -- {{args}}

# Generate and open docs
docs:
    cargo doc --open --no-deps

# Check MSRV
check-msrv:
    cargo msrv verify

# Update dependencies
update:
    cargo update

# Clean build artifacts
clean:
    cargo clean

# Watch mode (requires cargo-watch)
watch *args:
    cargo watch -x "test" -x "clippy" {{args}}

# Coverage (requires cargo-llvm-cov)
coverage:
    cargo llvm-cov --html
    @echo "Report: target/llvm-cov/html/index.html"
```

## Notes

- Prefer `cargo nextest` over `cargo test` if the project uses it — check for `.config/nextest.toml`
- For workspaces, add `--workspace` to test/clippy/build recipes
- If the project uses `cargo-make`, that's a different tool — migrate tasks to just recipes
- For binary crates, add `install` recipe: `cargo install --path .`
- For library crates, add `publish` recipe with `--dry-run` guard
