# ADR-002: Use a single `live` profile with strict compile targets

- **Context:** The current live deployment is split between `global` for Claude/Codex/Cursor/Copilot under `$HOME` and `opencode-global` for opencode under `$HOME/.config/opencode`.
- **Decision:** Replace the split with `profiles/live/profile.yaml` declaring `compile_targets` for `home` and `opencode`; require strict validation of target roots, harness membership, env resolution, and harness-specific fields.
- **Alternatives:** Keeping the split profiles minimizes migration work but preserves the mental split. Moving target grouping into chezmoi makes deployment topology fully chezmoi-owned but splits profile intent from compile topology.
- **Consequences:** `dots sync` has one live profile to compile, and opencode's path split is explicit. Old `global` / `opencode-global` commands and docs must be removed or changed to failing guidance.
