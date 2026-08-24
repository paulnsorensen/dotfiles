# Zed + Codex (ACP)

Zed is installed as a macOS-only Homebrew cask (`zed: { source: cask, platform: mac }` in
`packages/packages.yaml`), following [zed.dev/docs/installation](https://zed.dev/docs/installation).
Codex runs inside Zed as an **external agent over ACP** (Agent Client Protocol), configured in
`chezmoi/dot_config/zed/settings.json.tmpl` → `~/.config/zed/settings.json`.

## Why an adapter, not `codex acp`

The installed Codex CLI (0.145.0) has **no native `acp` subcommand** — its ACP surface is the
newer `app-server`. Zed talks to Codex through a separate adapter:

- The original `zed-industries/codex-acp` binary was **archived 2026-07-22**; development moved to
  **`@agentclientprotocol/codex-acp`** (npm, a Rust binary built on Codex's app-server).
- We pin that adapter in `packages/packages.yaml` as an npm package (`codex-acp`, mac-only) rather
  than relying on `npx` at runtime or Zed's ACP Registry auto-install. The Registry path installs
  the same adapter but leaves nothing in the dotfiles.

## How the binary path resolves

`settings.json` uses `agent_servers.Codex` with `type: custom`. The `command` is a chezmoi template
that resolves the installed bin, falling back to the bare name: `(or (lookPath "codex-acp")
"codex-acp") | quote`.

`packages/sync.sh` runs **before** the final `chezmoi apply` (see `.sync`), so `npm install -g`
lands the `codex-acp` bin (npm global prefix `/opt/homebrew`) before chezmoi renders the template,
and `lookPath` resolves the absolute path. On a host where it isn't installed yet, the template
falls back to the bare name `codex-acp` (PATH resolution).

## Auth and secrets

`env` is `{}` — the adapter reuses your `~/.codex` login (ChatGPT login / Codex API key / OpenAI
API key, whichever Codex is configured with). No secrets live in the Zed config, consistent with
the repo's no-plaintext-secrets rule.

## Gotchas

- Non-darwin hosts are gated out in `chezmoi/.chezmoiignore` (`.config/zed/**`), since the cask is
  mac-only.
- If Codex fails to start when Zed is launched from Finder/Dock (vs. the `zed` CLI), suspect a
  minimal GUI `PATH` — the adapter may need `codex` on `PATH` to reach the app-server. Launching
  Zed from a shell, or adding a `PATH` entry under `agent_servers.Codex.env`, resolves it.
- Bump the pinned `codex-acp` version in `packages/packages.yaml` (renovate tracks
  `@agentclientprotocol/codex-acp`).
