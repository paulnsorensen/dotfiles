# Brew machine prune — completing the pinning migration's machine side

The manifest-pinned-packages migration ([[adr/manifest-pinned-packages]]) shrank the *repo-side* brew list to a ~16-formula remainder, but `sync_brew` (packages/sync.sh) only installs/upgrades manifest entries — it never uninstalls strays, so the machine kept ~73 brew leaves. On 2026-07-27 the machine was pruned to match: 45 formulae duplicating mise pins removed (`brew leaves` 73→31), plus brew `tailscale` (double-install with the standalone app — packages.yaml:27-30 warns never to run two variants side by side), brew `ruff` (duplicated the uv pin), and the `rectangle` cask (superseded by manifest `rectangle-pro`). `serena-agent` and unmanaged `code-review-graph` uv tools uninstalled.

## Gotchas found during the prune

- **rustup must stay in brew.** mise's `rust` entry is a *symlink* to `~/.cargo/bin` — rust is rustup-managed underneath, not mise-installed. Uninstalling brew rustup would orphan every toolchain. Verify with `readlink ~/.local/share/mise/installs/rust/<ver>`.
- **mise itself stays in brew** — it is the bootstrap trust root (`brew must install mise before sync_mise()`); shims point at `/opt/homebrew/bin/mise`.
- Before uninstalling a brew formula that a mise pin duplicates, confirm the mise copy wins PATH (`which -a <tool>` → mise install dir first). All 45 did.

## Accepted-unmanaged boundary (do not re-flag)

These installs are deliberately outside the pin contract. Work projects under `~/Dev/multiplier` were scanned (2026-07-27) and **veto** removal of the starred items:

- **docker, docker-compose, colima*** — live compose files in `warden/docker/`, `.devcontainer/`, `infra/local/`
- **kubernetes-cli*** — GKE/skaffold deploys under `infra/cloud-deploy/`, `infra/k8s/`
- **yarn*** — `"packageManager": "yarn@4.x"` in multiplier package.json
- **biome*** — `biome.jsonc` at multiplier root + warden
- **postgresql@15, redis, temporal** — stopped brew services; multiplier `.env*` reference localhost ports (compose-vs-brew backing ambiguous, kept "just in case")
- **gcloud-cli, 1password-cli casks** — GKE deploys; chezmoi `onepasswordRead` needs `op`
- **yabai** — driven by skhd/skhdrc
- **python@3.12, poppler, yamlfmt, yamllint, markedit, fonts** — no evidence either way; left installed
- **starship, zellij, gnu-sed** — zero references in dotfiles *and* multiplier; approved for removal (pending manual `brew uninstall starship zellij gnu-sed` — agent classifier blocked the batch)

Related: [[sync-and-chezmoi]], [[adr/manifest-pinned-packages]].
