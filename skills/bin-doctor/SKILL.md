---
name: bin-doctor
description: >
  Audit and repair installed binaries so each tool has one install path, a
  clean cache, and a current pin, across mise, Homebrew, cargo, uv, npm, pnpm,
  bun, pipx, and Go. Use when the user says "clean up my binaries", "which
  cargo am I running", "duplicate installs", "old cargo binaries", "shadowed
  binary", "stale ~/.cargo/bin", "are my tools up to date", "prune caches", or
  invokes /bin-doctor, and when a tool reports an unexpected version. Do NOT
  use for project dependency conflicts (/version-doctor) or harness config
  drift (/harness-doctor).
model: sonnet
effort: medium
license: MIT
metadata:
  author: paulnsorensen
---

# bin-doctor

Bring the machine back to the dotfiles install contract, then keep it clean and current.

The contract: `chezmoi/dot_config/mise/config.toml` pins every tool that mise can install.
`packages/packages.yaml` owns the brew, cask, npm, uv, cargo, and gh-extension remainder.
`packages/bin-doctor.allow` lists accepted exceptions, each with a reason.
Any other copy of a binary is a finding, even when the right copy wins PATH today.

`bin/bin-doctor` in the dotfiles repo does the detection. This skill does the judgment: owner, fix, and approval.

## Inputs

The text after the skill name selects a mode: `check` (default), `clean`, or `outdated`.
A tool name narrows `check` to the findings for that tool.

## Flow

1. **Detect.** Run `bin-doctor check` from an interactive login shell (`zsh -ic 'bin-doctor check'`).
   Run it again from a plain shell.
   Both PATHs matter: agents and timers use the non-interactive one.
   Done when you have both finding lists.
2. **Classify each finding.** Pick one fix per finding with the table below. Read `references/managers.md` for the exact per-manager command.
   Done when every finding has an owner and a fix.
3. **Ask once.** Show the plan table (Output) and get approval for every uninstall and every manifest edit.
   A PR body or a report is not approval.
4. **Apply.** Run the approved uninstalls.
   Edit manifests at their source (`chezmoi/dot_config/mise/config.toml`, `packages/packages.yaml`, `packages/bin-doctor.allow`), never the rendered `~/.config/mise/config.toml`.
   Run `dots sync` after a manifest edit.
   Done when `bin-doctor check` shows no findings except any the user declined.
5. **Clean** (mode `clean`, or after apply). Run `bin-doctor clean --dry-run` and show the plan.
   Then run `bin-doctor clean`.
   Confirm the weekly job: `systemctl --user list-timers bin-doctor-clean.timer` on Linux, `launchctl print gui/$(id -u)/com.dotfiles.bin-doctor-clean` on macOS.
6. **Currency** (mode `outdated`). Run `bin-doctor outdated`.
   Pinned tools move only through merged Renovate PRs. List the open ones (`gh pr list --search "renovate"`) instead of upgrading in place.

| Finding | Default fix |
|---|---|
| `shadow` | Keep the manifest owner's copy; uninstall every other copy. No owner yet: declare it first. |
| `conflict` (brew `rust`) | `brew uninstall rust`; rustup plus the mise `rust` pin own the toolchain. |
| `cargo-stray`, `uv-stray`, `npm-stray`, `brew-stray` | Declare it (mise when `mise ls-remote aqua:<owner>/<repo>` lists it, else packages.yaml), or uninstall it if unused. |
| `cargo-stale` | Delete the crate's entries from `~/.cargo/.crates.toml` and `~/.cargo/.crates2.json`; `cargo uninstall` refuses. |
| `cargo-untracked` | Delete the file when another manager owns the tool; else reinstall through the manifest. |
| `unmanaged` (pipx, go, bun) | Move the tool to mise or uv, then uninstall the old copy. |
| Accepted exception | Add `<kind>:<name>  # reason` to `packages/bin-doctor.allow`. |

## Output

```markdown
## bin-doctor: <N> findings (<interactive N> interactive, <plain N> plain shell)

| # | Tool | Finding | Copies (winner first) | Owner | Fix | Approved |
|---|---|---|---|---|---|---|

Clean: <steps run, space freed if the tool reports it> · Timer: <next run | not enabled>
Outdated: <N pins behind; open Renovate PRs: #…>
```

## What this skill never does

- It never uninstalls or edits a manifest without approval in this conversation.
- It never removes brew `mise` or brew `rustup`: they are the bootstrap trust roots.
- It never upgrades a pinned tool in place (`mise upgrade --bump`, `brew upgrade <pinned>`); that defeats the Renovate pin.
- It never runs `brew bundle cleanup --force`, `topgrade`, or `uv python uninstall` unattended.

## Gotchas

- mise's `rust` entry is a symlink to `~/.cargo/bin`, so mise makes shims for every cargo-installed binary. `bin-doctor` ignores those shims; do not "fix" them.
- A `cargo uninstall` of a binary that is already gone fails with "corrupt metadata". That is `cargo-stale`, fixed by editing the metadata files.
- `brew leaves` lists tap formulae by full name (`owner/tap/name`); declare the short name.
- A second npm global prefix (brew node beside mise node) can hide a stale copy; `bin/lib/npm-nightly.sh` prunes the own-authored nightlies.

## References

- `references/managers.md` — read when you choose the exact inventory, uninstall, cleanup, or update command for one manager.
  Also read it when the user asks why a tool such as topgrade is not used.
