# mise config precedence can deadlock `dots sync`

`mise` loads `~/.config/mise/config.toml` (the **live, chezmoi-deployed**
config) *after* any `--source`/`MISE_GLOBAL_CONFIG_FILE` manifest and lets it
win. That single ordering fact caused an 8-day-old `dots sync` deadlock
(PR #677, closed #589's regression): a pin bump landed in the repo, but the
live config on the affected machine was still 2 days stale, so:

- `MISE_GLOBAL_CONFIG_FILE` pointed `mise install` at the tracked manifest,
  but the live file still won the merge — `mise install` never requested the
  bumped version.
- `verify_harness_versions` (in `.sync`) checks the installed binary against
  the pinned version and gates the **final** `chezmoi apply` on it passing —
  it's the sync's authority on whether package convergence actually produced
  the pinned harnesses.
- The gate saw the old binary and skipped that final apply.
- But the final apply was the *only* step that would have refreshed the live
  `config.toml` to the new pin.

No re-run escapes that: each attempt reproduces the same stale read. The fix
is ordering, not retrying — the manifest is an **input** to package
convergence, not an **output** of it. `run_sync` in `.sync` now exports
`MISE_CONFIG_FILE` pointing at the tracked repo source
(`chezmoi/dot_config/mise/config.toml`) for *both* calls into
`packages/sync.sh`: the early bootstrap-only call (before chezmoi exists) and
the main package-convergence call in the two-phase `prepare` → package-sync →
`final` chezmoi-apply sequence. A failed final apply now warns and records a
`SYNC_FAILURES` entry rather than aborting the whole run — upgraded packages
are retained even if the harness-version re-check still fails.

See `.sync:run_sync` (the `MISE_CONFIG_FILE=...` exports and the
`verify_harness_versions` calls bracketing `CHEZMOI_SYNC_PHASE=final`) and
`packages/sync.sh:mise_config_path`/`sync_mise` for the mechanism; both carry
inline comments recording this precedence rule.

## Two adjacent fixes landed in the same PR

Same investigation, same symptom class (`dots sync` failing for reasons that
look unrelated to the actual defect):

- **omp install hit `ETXTBSY`.** The omp.sh installer curls its release asset
  straight onto the live binary path; any running `omp` session holds that
  inode open for write and the kernel refuses the write —
  `curl: (23) client returned ERROR on write` reads like a network fault but
  isn't. `converge_omp_native` in `packages/sync.sh` now stages the download
  into a sibling directory and `mv`s it into place — `rename(2)` swaps the
  directory entry, leaving already-running processes on the old inode.
- **mise's aqua/GitHub reads went unauthenticated and self-defeated.** `gh`
  stores its token in the macOS keychain, so `~/.config/gh/hosts.yml` has no
  `oauth_token` field and mise's default `github.gh_cli_tokens` reader finds
  nothing — falling back to the 60/hr anonymous cap, which pins with no
  prebuilt binary and no cached remote-versions list (`tmux-builds`,
  `protobuf/protoc`, `rust-analyzer`, `nextest/cargo-nextest`) exhaust and
  then re-exhaust every run, since a rate-limited 403 caches nothing. Fixed by
  exporting `MISE_GITHUB_CREDENTIAL_COMMAND="gh auth token"` — **must be the
  env var**, not a `[settings]` block in `config.toml`: `sync_mise` points
  `MISE_GLOBAL_CONFIG_FILE` at the source manifest, which demotes the live
  config to *non-global*, and mise ignores `credential_command` in a
  non-global config as untrusted. A `settings.toml` doesn't work either — the
  mise version in use only reads `config.toml`. Wired in both `zsh/core.zsh`
  (interactive shells) and `packages/sync.sh:sync_mise` (bootstrap/CI), each
  guarded on `gh` being present.

Related: [[operations/sync-and-chezmoi]] (the prepare/package-sync/final
phase ordering this deadlock lives inside), [[operations/mise-aqua-backend-retypes]]
(a different mise pin failure mode — backend retyping, not config precedence).
