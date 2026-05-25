# Rust Conventions

- Run `cargo fmt` and `cargo clippy --all-targets --all-features -- -D warnings` before committing.
- Prefer `?` over `.unwrap()` outside of tests and `main`.
- Use `cargo nextest run` if available (faster, better output); fall back to `cargo test`.
- Use `tracing` over `println!` for anything that's not a one-off debug.
- Reach for `anyhow` for application error handling, `thiserror` for library errors.
- Keep `mod` declarations and `pub use` re-exports at the top of each file, alphabetized within a group.
