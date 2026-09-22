# Rust local build, test, and check options

Use `cargo check` for a fast diagnostic loop. It skips code generation and linking, so it does not replace build or test coverage. [Cargo check](https://doc.rust-lang.org/cargo/commands/cargo-check.html)

`cargo build` checks code generation and linking. `cargo test` checks runtime behavior. Keep `cargo clippy` for lint coverage. Clippy invokes Cargo check; it does not replace build or test gates. [Clippy source](https://github.com/rust-lang/rust-clippy/blob/master/src/main.rs)

## cargo-nextest

Nextest runs tests in separate processes. Tests can still share files, ports, databases, and other external resources. Configure unique resources before enabling parallel runs. [Nextest documentation](https://nexte.st/docs/)

Use `--test-threads` to limit nextest test concurrency. Nextest does not run doctests. Run `cargo test --doc` for doctest coverage. [Nextest configuration](https://nexte.st/docs/configuration/reference/)

## sccache and incremental compilation

Sccache rejects incremental Rust inputs. Cache behavior varies by crate type. System-linker crates are not cacheable. Inspect sccache statistics for the selected workspace and crate types. Do not promise zero cache hits. [Sccache Rust caveats](https://github.com/mozilla/sccache/blob/main/docs/Rust.md)

## Linkers

Choose a linker that supports the target platform. Measure repeated comparable builds before and after the change. Do not assume a linker speed multiplier. Configure the linker through Cargo settings only when the target supports it. [Cargo configuration](https://doc.rust-lang.org/cargo/reference/config.html)

## Nightly options

Check the pinned compiler's supported options before using an unstable experiment. Require approval for toolchain changes. Provide a fallback for experiments. Keep stable-toolchain gates independent. [Rust compiler options](https://doc.rust-lang.org/nightly/unstable-book/compiler-flags/threads.html)

## Profiling

Use `cargo build --timings` to locate slow units and concurrency limits. Compare repeated equivalent command runs to measure a change. The timing report diagnoses work; it does not replace a build or test gate. [Cargo timings](https://doc.rust-lang.org/cargo/reference/timings.html)
