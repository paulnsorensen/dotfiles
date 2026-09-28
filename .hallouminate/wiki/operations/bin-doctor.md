# bin-doctor — one install path per binary

`bin/bin-doctor` enforces the install contract from [[adr/manifest-pinned-packages]]. mise pins every tool it can install, `packages/packages.yaml` owns the remainder, and `packages/bin-doctor.allow` lists accepted exceptions with a reason. The `/bin-doctor` skill does the triage and asks before any uninstall. `dots doctor` runs `bin-doctor check`.

## Why a detector exists

`sync_brew`, `sync_cargo`, and the other installers only install and upgrade. They never remove a copy that another manager also provides. On 2026-09-27 the Linux box had 51 commands with two or more installed copies. The worst was the brew `rust` formula: brew's bin sat ahead of the rustup proxies. `cargo` ran 1.97.1 (Homebrew) while the mise `rust` pin said 1.98.1. No maintained tool detects shadowing across managers (researched 2026-09-27; `mise doctor` and `brew doctor` check only their own domain).

## Decisions

- **Linux uses brew's rustup proxies too.** `zshenv` and `zsh/core.zsh` put `$HOMEBREW_PREFIX/opt/rustup/bin` ahead of brew's bin on both platforms. `bin-doctor` reports a brew `rust` formula beside rustup as a `conflict`.
- **aqua before cargo.** A crate with release binaries in the aqua registry is a mise pin (cargo-deny, cargo-dist, mdbook, cargo-nextest). `packages.yaml` `source: cargo` is only for source-only crates (cargo-update, cargo-cache, bws).
- **Weekly `bin-doctor clean`.** A systemd user timer (Linux) or a launchd agent (macOS), both deployed by chezmoi and enabled by `run_onchange_after_install-bin-doctor-clean.sh.tmpl`. It runs only prompt-free cleanups that delete re-downloadable data.
- **Rejected:** topgrade and brew autoupdate (in-place upgrades defeat the Renovate pins), cargo-sweep (unmaintained), `brew bundle cleanup` (needs a Brewfile and `--force`). The research report is `research/binary-manager-cleanup-hygiene` in the cheese corpus.

## Gotchas

- **mise shims for cargo binaries are not duplicates.** mise's `rust` entry is a symlink to `~/.cargo/bin`, so mise makes a shim for every `cargo install` binary. `bd_check_shadows` counts a shim only when a non-cargo mise bin dir holds that command.
- **Deleting rustup's proxies from `~/.cargo/bin` is safe only with brew rustup on PATH.** The mise `rust` pin sets `RUSTUP_TOOLCHAIN`; any rustup proxy then selects the pinned toolchain.
- **`cargo uninstall` refuses a crate whose binary is already gone** ("corrupt metadata"). Remove its entries from `~/.cargo/.crates.toml` and `~/.cargo/.crates2.json`.
- **Check both PATHs.** Interactive zsh (`mise activate`) and non-interactive shells (mise shims from `zshenv`) resolve differently; agents and timers use the non-interactive one.
- **systemd user timers need a session.** Without `loginctl enable-linger`, the timer runs only while the user is logged in; `Persistent=true` catches up a missed week.

Related: [[operations/brew-machine-prune]] (the macOS prune and the accepted-unmanaged list the allowlist copies), [[operations/mise-manifest-precedence]].
