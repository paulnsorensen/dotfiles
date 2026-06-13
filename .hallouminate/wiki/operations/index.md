# Operations

The repo's operational plumbing — the machinery that deploys config and the local dev environment, as opposed to [[../architecture/index]] (the agent-config system) and [[../harnesses/index]] (per-harness wiring).

- [[local-llm]] — the opt-in local-LLM stack: llama.cpp workers behind a LiteLLM proxy, the `localLLM` chezmoi gate, what's managed vs. runtime-only, and the `llm-*` commands.
- [[sync-and-chezmoi]] — how `dots sync` deploys (the symlink + `.sync` system, `SYNC_SKIP_LIST`, `bin/` PATH-from-clone), the chezmoi-managed subset, and the "shell functions need tests" convention.
- [[dev-environment]] — git tooling (difftastic, mergiraf, the conflict-resolution chain), prek pre-commit hooks, Claude marketplace plugins, and skhd.
- [[tmux-plugin-gotchas]] — tmux plugin wiring: why continuum silently disarms when `status-right` is rewritten after TPM runs, the required plugin declaration order, catppuccin palette injection via `theme/generate.sh`, and the live vs. repo plugin tree.
