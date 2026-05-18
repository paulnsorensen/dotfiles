---
name: cargo-workflow
description: Standard cargo workflow for build/test/lint cycles.
---

# Cargo Workflow

Use this skill when working on Rust code that compiles via cargo.

## Standard cycle

```bash
cargo check          # fast type-check (use first)
cargo test           # run tests
cargo clippy         # lint (treat warnings as errors)
cargo fmt            # format
```

## Common patterns

- For long-running test suites, prefer `cargo nextest run` if `cargo-nextest` is installed.
- Use `cargo check --message-format=json` when you need structured diagnostics.
- For workspace members, scope with `-p <crate>` to avoid recompiling the world.

## When tests fail

1. Re-run with `--nocapture` to see prints.
2. Run a single test: `cargo test -p <crate> <test_name> -- --exact --nocapture`.
3. For flakes, run with `--test-threads=1` to rule out concurrency.
