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

# Coverage report (requires cargo-llvm-cov, preferred over cargo-tarpaulin)
coverage:
    cargo llvm-cov --all-features --workspace --html
    @echo "Report: target/llvm-cov/html/index.html"

# Enforce coverage threshold (fails if below)
cov-check:
    cargo llvm-cov --all-features --workspace \
        --fail-under-lines 80 \
        --fail-under-functions 70

# Ratchet: never let overall coverage regress (reads/writes .coverage-baseline)
cov-ratchet:
    #!/usr/bin/env bash
    cargo llvm-cov --all-features --workspace --json --summary-only \
        > /tmp/llvm-cov.json
    CURRENT=$(jq '.data[0].totals.lines.percent' /tmp/llvm-cov.json)
    BASELINE=$(cat .coverage-baseline 2>/dev/null || echo 0)
    awk -v c="$CURRENT" -v b="$BASELINE" 'BEGIN{exit !(c>=b)}' \
        && echo "$CURRENT" > .coverage-baseline \
        || { echo "Coverage regression: $CURRENT% < $BASELINE%"; exit 1; }
```

## Coverage notes

- **Per-file thresholds**: not native in cargo-llvm-cov as of 2026 (issue #3693). The ratchet approach is the best available alternative.
- **cargo-llvm-cov over cargo-tarpaulin**: faster, LLVM-native, better JSON/lcov output, and actively maintained. Use tarpaulin only if the project already depends on it.
- Commit `.coverage-baseline` to source control so CI enforces the ratchet.

## Notes

- Prefer `cargo nextest` over `cargo test` if the project uses it — check for `.config/nextest.toml`
- For workspaces, add `--workspace` to test/clippy/build recipes
- If the project uses `cargo-make`, that's a different tool — migrate tasks to just recipes
- For binary crates, add `install` recipe: `cargo install --path .`
- For library crates, add `publish` recipe with `--dry-run` guard
