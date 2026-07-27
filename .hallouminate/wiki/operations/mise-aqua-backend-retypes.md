# mise gotcha — aqua-registry package retypes break pins without a version change

The aqua registry can retype a package upstream (e.g. when a project stops
shipping prebuilt binaries). mise's aqua backend only supports binary-type
packages, so a pin that installed fine yesterday fails today with
`package type X is not supported in the aqua backend` — **the version is
irrelevant; the fix is a backend migration, not a version bump.**

Observed 2026-07-27 (session: dots sync failure):

- `aqua:XAMPPRocky/tokei` and `aqua:eza-community/eza` retyped to `cargo`
  → migrated to `cargo:tokei` / `cargo:eza` (bare crates.io semver, compiled
  by the mise-managed rust toolchain; no cargo-binstall on the machine).
- `aqua:golang.org/x/tools/gopls` is `go_install`-type — unusable via aqua
  AND the go backend needs a full Go toolchain. gopls was **dropped** from
  the manifest (no Go work on this machine; `bin/gopls` wrapper pointed at a
  long-gone `/opt/homebrew/bin/gopls` and was deleted too). Re-add alongside
  a pinned `go` core-plugin entry if Go work starts.

Verify a backend migration before editing: `mise ls-remote <backend>:<pkg>`
must list the pinned version. `tests/mise-config.bats` asserts the manifest
tool count and per-backend pins — update it in the same change.

Related fallout: the pinning migration's brew shrink removed brew bash 5, so
`/bin/bash` (3.2) is now the only bash on PATH. Under `set -u`, bash 3.2
treats empty-array expansion `"${arr[@]}"` as unbound (legal in bash 4.4+) —
a latent class of breakage in `bin/` scripts that CI (newer bash) never
catches. Guard with `${arr[@]+"${arr[@]}"}` (fixed in `bin/dotsclaude`;
`tests/cc-env.bats` test 109 is the canary).

Related: [[adr/manifest-pinned-packages]], [[operations/sync-and-chezmoi]].
