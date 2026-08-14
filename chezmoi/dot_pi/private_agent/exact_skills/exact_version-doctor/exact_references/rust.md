# Rust — Cargo.toml Workspace Patterns

## Workspace Inheritance

A Cargo workspace has a root `Cargo.toml` with `[workspace]` and member crates.

### Root Cargo.toml (workspace)

```toml
[workspace]
members = ["crates/*"]
resolver = "2"

[workspace.package]
version = "0.1.0"
edition = "2024"
rust-version = "1.85"

[workspace.dependencies]
serde = { version = "1.0", features = ["derive"] }
tokio = { version = "1", features = ["full"] }
anyhow = "1.0"
```

### Member Cargo.toml (inherits from workspace)

```toml
[package]
name = "my-crate"
version.workspace = true
edition.workspace = true

[dependencies]
serde.workspace = true
tokio.workspace = true
# Member-specific deps go here directly
clap = { version = "4", features = ["derive"] }
```

## Common Version Errors

### "version X doesn't match workspace"

**Cause:** Member specifies a version that conflicts with workspace.
**Fix:** Remove the version from the member; use `.workspace = true`.

```toml
# WRONG — member overrides workspace version
serde = "2.0"

# RIGHT — inherit from workspace
serde.workspace = true
```

### "package X not found in workspace dependencies"

**Cause:** Member uses `.workspace = true` but workspace doesn't declare the dep.
**Fix:** Add the dependency to `[workspace.dependencies]` in root Cargo.toml.

### Feature conflicts

**Cause:** Workspace declares dep with features A, member needs feature B.
**Fix:** Add features at workspace level (they unify across all members).

```toml
# In workspace root — add the missing feature
[workspace.dependencies]
tokio = { version = "1", features = ["full", "test-util"] }
```

### "failed to select a version for X"

**Cause:** Two deps require incompatible versions of X.
**Fix:** Check `cargo tree -i <package>` to find who requires what. Update the
constraint in workspace root to satisfy both, or update the dep that's pinning
to an old version.

```bash
# Find who depends on what version
cargo tree -i serde
cargo tree -d  # show duplicates
```

## Lock File

- `Cargo.lock` is the source of truth for exact versions
- `cargo update` refreshes the lock file within constraint ranges
- `cargo update -p <package>` updates a single package
- After changing version constraints, always run `cargo check`

## Version Syntax

```toml
"1.0"       # >= 1.0.0, < 2.0.0 (caret, default)
"~1.0"      # >= 1.0.0, < 1.1.0 (tilde)
"=1.0.5"    # exactly 1.0.5
">=1.0, <2" # range
```

## Workspace vs Member — Where to Put What

| Config | Where |
|--------|-------|
| Shared dependencies | `[workspace.dependencies]` in root |
| Shared metadata (version, edition) | `[workspace.package]` in root |
| Member-only dependencies | `[dependencies]` in member |
| Feature selection | Prefer workspace level (features unify) |
| Build scripts | Member level (build.rs is per-crate) |
