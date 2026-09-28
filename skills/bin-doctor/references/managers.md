# Manager command reference

Checked: 2026-09-27. Sources: the research report `research/binary-manager-cleanup-hygiene` in the cheese corpus, plus local `--help` output (mise 2026.7.14, cargo-cache 0.8.3, cargo-update 22.1.0, brew 4.x).

"Unattended" means safe for the weekly `bin-doctor clean` job: no prompt, and it deletes only data the manager can download or build again.

## Inventory, uninstall, cleanup, update

| Manager | Inventory | Uninstall | Cache cleanup (unattended) | Update report (read-only) |
|---|---|---|---|---|
| mise | `mise ls --current`, `mise bin-paths`, `mise which <bin>` | remove the pin from the chezmoi source, then `mise prune --yes` (manual only, needs approval) | `mise cache prune` | `mise outdated` |
| Homebrew | `brew leaves`, `brew list --formula` | `brew uninstall <name>`; `brew autoremove` removes orphaned dependencies (manual only, needs approval) | `brew cleanup --prune=30` | `brew outdated` |
| cargo | `cargo install --list` | `cargo uninstall <crate>` | `cargo cache --autoclean` (extracted sources and git checkouts; archives stay) | `cargo install-update --list` |
| rustup | `rustup toolchain list` | `rustup toolchain uninstall <tc>` | none needed | pins move with the mise `rust` entry |
| uv | `uv tool list` | `uv tool uninstall <name>` | `uv cache prune` (dangling entries) | `uv tool list --outdated` |
| npm | `npm ls -g --depth=0` | `npm rm -g <pkg>` | `npm cache verify` (garbage-collects, keeps valid data) | `npm outdated -g` |
| pnpm | `pnpm ls -g` | `pnpm rm -g <pkg>` | `pnpm store prune` | — |
| bun | `ls ~/.bun/bin` | `bun rm -g <pkg>` | `bun pm cache rm` | — |
| pipx | `pipx list --short` | `pipx uninstall <name>` | no cache command | `pipx list` |
| Go | `ls "${GOBIN:-$HOME/go/bin}"`, `go version -m <bin>` | delete the binary | `go clean -cache -testcache` | none built in (`gup check` exists; not adopted) |

## Deliberately not adopted

| Tool or command | Reason |
|---|---|
| `topgrade` | Upgrades every manager in place, which defeats the Renovate pins. No documented way to respect a pinned manifest. |
| `brew autoupdate` (DomT4 tap) | Same conflict: it upgrades brew formulae on a timer. `dots up` owns the brew remainder. |
| `brew bundle cleanup` | Prompts and exits 1 unless `--force`; with `--force` it uninstalls everything outside a Brewfile. This repo has no Brewfile. |
| `cargo-sweep` | Its README marks it unmaintained. It cleans project `target/` dirs, not installed binaries. |
| `cargo clean gc` / `-Zgc` | Nightly-only. Stable cargo (1.88+) already runs automatic cache GC; `[cache] auto-clean-frequency` sets the cadence. |
| `npm cache clean --force` | npm docs call it unnecessary; `npm cache verify` is the routine command. |
| `mise upgrade --bump` | Rewrites pins locally; pins change only through merged Renovate PRs. |
| `uv python uninstall --all` | No dry run; removes interpreters that projects may use. |

## Scheduling facts

- systemd user timers stop at logout unless `loginctl enable-linger "$USER"` is set. `Persistent=true` runs a missed week at the next start.
- launchd agents load with `launchctl bootstrap gui/$(id -u) <plist>`; `load`/`unload` are deprecated. A job missed during sleep runs at wake.
- Neither launchd nor systemd reads shell rc files. `bin-doctor` builds its own PATH (`bd_bootstrap_path`).
