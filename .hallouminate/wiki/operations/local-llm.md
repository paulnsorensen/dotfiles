# Local LLM Stack

A bespoke, **per-machine and opt-in** local-LLM stack at `~/local-llm/` — llama.cpp workers behind a LiteLLM proxy at `http://127.0.0.1:4000/v1` (dummy key `sk-local`) exposing OpenAI-compatible model names (`local-sonnet`, `local-haiku`, `local-coder`, `local-opus`, `local-vision`, `local-classifier`).

## Why opt-in and gated

The stack is heavy (85G of models, a built llama.cpp + lemonade) and machine-specific, so it must never deploy by accident on a fresh box. It's gated by the chezmoi `localLLM` flag (`.chezmoi.toml.tmpl`): `dots sync` prompts *"Manage local LLM stack on this machine?"* on first init (persisted to `~/.config/chezmoi/chezmoi.toml`; re-prompt by deleting that file). When off, `.chezmoiignore` skips the whole tree so nothing deploys.

## Managed (in-repo) vs. runtime (not managed)

The split exists so secrets and giant binaries stay off the repo while the *wiring* is reproducible.

**Managed (chezmoi sources):**

- `chezmoi/local-llm/configs/litellm.yaml` → `~/local-llm/configs/litellm.yaml` (proxy routing + fallbacks).
- `chezmoi/local-llm/scripts/executable_{aliases,install-npu,healthcheck,download-models}.sh` → `~/local-llm/scripts/` (the `executable_` prefix is stripped on render).
- `chezmoi/dot_config/systemd/user/{litellm,local-llm.target,worker-*}` → `~/.config/systemd/user/` (verbatim; `%h`-portable, no secrets). Unit *files* only — enablement stays a runtime action.
- opencode `local-llm` provider — `chezmoi/lib/install-local-llm.sh` jq-merges the `.provider` block into `~/.config/opencode/opencode.json` (mirrors the MCP `.mcp` sync), driven by `run_onchange_after_install-local-llm.sh.tmpl`, which also runs `systemctl --user daemon-reload`. Edit models/endpoint there, not in the live file.

**Not managed (runtime / prerequisites):** the 85G `~/local-llm/models/`, the built `~/local-llm/bin/` (llama.cpp + lemonade), `~/local-llm/logs/`, and the `~/.local/bin/litellm` install. The sync never auto-enables or starts workers — that stays explicit (`llm-up`).

## Commands

Aliases from `scripts/aliases.sh`. These require a one-time manual `echo 'source ~/local-llm/scripts/aliases.sh' >> ~/.zshrc` (per `local-llm/README.md`) — the managed `zshrc` does not source them, mirroring how `bin/` and the litellm install are manual prerequisites.

- `llm-up` / `llm-down` / `llm-status` — start/stop/inspect via systemd.
- `llm-test` (= `healthcheck.sh`) — smoke test: hard tiers (litellm + worker-igpu + worker-cpu) must answer with non-empty completions; optional tiers are informational and flagged when served by a LiteLLM fallback. `llm-test --opencode` adds an end-to-end probe through the wired provider.
- `llm-download` (= `download-models.sh`) — on-demand, idempotent GGUF fetch (skips present files). Never run by sync.
- `dots doctor` runs `healthcheck.sh --quiet` automatically when the stack is deployed (presence-gated on `~/local-llm/scripts/healthcheck.sh`).

## Adding / tuning a model

Add a worker unit under `chezmoi/dot_config/systemd/user/` → add the route to `litellm.yaml` → add the model name to the provider block in `chezmoi/lib/install-local-llm.sh` → `chezmoi apply` (runs `daemon-reload`) → `llm-test`.

> Gotcha: the three Qwen3 repo IDs in `download-models.sh` (sonnet/haiku/coder) are **unverified** — they follow the unsloth `<Model>-GGUF` convention of the confirmed opus repo but weren't recorded on the source machine. Confirm on huggingface.co before a fresh-machine download (`hf download` fails loud on a wrong repo).
