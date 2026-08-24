# Zed + Codex (ACP)

Zed is installed as a macOS-only Homebrew cask (`zed: { source: cask, platform: mac }` in `packages/packages.yaml`). Codex runs inside Zed as ACP External Agents, configured by `chezmoi/dot_config/zed/settings.json.tmpl` and rendered to `~/.config/zed/settings.json`.

## Two retained Codex entries

The live configuration contains two distinct Codex entries, both preserved in chezmoi:

- `codex-acp` is Zed's ACP Registry agent with `fast-mode: true`.
- `Codex` is the repository-managed custom agent that launches the pinned `@agentclientprotocol/codex-acp` executable.

Do not collapse these entries without an explicit user decision: the registry entry was added through Zed and the custom entry is the established repository configuration. The npm package remains pinned in `packages/packages.yaml` because the custom entry resolves it with chezmoi's `lookPath`.

Codex retains its native authentication and billing configuration. No credentials belong in Zed settings or this repository.

## Operational boundary

- Zed launches the configured ACP agent and hosts its thread; Codex owns runtime, model selection, authentication, and native permissions.
- Non-darwin hosts ignore `.config/zed/**` through `chezmoi/.chezmoiignore`, because Zed is a macOS-only cask here.
- The ACP Registry is the normal place to repair or reinstall the registry-backed entry: run `zed: acp registry` from Zed's Command Palette.

See [[zed-workspace-and-agents]] for the shared workspace layout, OMP sidecar, and deuteranopia theme decisions.

## Sources

- [Zed External Agents](https://zed.dev/docs/ai/external-agents)
- [ACP Registry](https://github.com/agentclientprotocol/registry)
