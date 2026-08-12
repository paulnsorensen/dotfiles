# Local LLM Stack

A bespoke, **per-machine and opt-in** local-LLM stack at `~/local-llm/` — llama-swap loads/unloads llama.cpp backends on demand behind a LiteLLM proxy at `http://127.0.0.1:4000/v1` (dummy key `sk-local`) exposing OpenAI-compatible model names (`local-sonnet`, `local-haiku`, `local-coder`, `local-embed`, `local-vision`, `local-classifier`).

## Architecture (post #287→#289 rightsize, 2026-06)

Always-on workers OOM'd the 59GiB Strix Point box (iGPU "VRAM" = system RAM), so the stack moved to on-demand serving (PR #296):

- **llama-swap (`:9000`)** routes by request model name and spawns/kills `llama-server` backends. Hot group (`local-haiku` + `local-embed`, `swap/exclusive: false, persistent: true`) stays resident; the pool (`sonnet`/`coder`/`vision`) swaps one-at-a-time, unloading after `globalTTL: 600` (coder `ttl: 900`). Cold loads are **held open** (no 503) up to `healthCheckTimeout: 360`.
- **LiteLLM (`:4000`)** fronts everything; llama-swap-served aliases all point at the single `:9000/v1` with per-model `timeout: 300` for cold swaps. `worker-npu` (`:8000`, lemond/FastFlowLM) stays a separate unit.
- **No opus tier**: dense-70B is bandwidth-capped to ~2 t/s on LPDDR5X — opus-grade work routes to cloud models (#289).
- `llama-swap.service` carries the #287 hardening pattern: `StartLimitBurst=3`/`StartLimitIntervalSec=120` in `[Unit]` (must exceed `RestartSec × burst`), `RestartSec=30`, `OOMScoreAdjust=1000`, `MemoryMax=30G`. Bounded-restart semantics: N kills consume the burst; the **N+1th start** inside the window is refused.

## Gotchas (hard-won, box-verified)

- **llama-swap v224 config nesting**: groups live at **top-level `groups:`**. The `routing.router.settings.groups` nesting only exists in post-v224 `main`, and v224 **silently ignores unknown keys** — the observed failure is every model sharing one global swap slot (hot members evicted). Top-level `groups:` remains supported in newer releases ("legacy… no plans to deprecate"), so prefer it. Don't ground schema research against `main` when the binary is pinned (`install-llama-swap.sh` pins v224).
- **No systemd specifiers in `llama-swap.yaml`**: `%h` is not expanded (llama-swap execs `cmd` directly, no shell) — use `${env.HOME}`. `--listen` is a CLI flag on the service, not a YAML key.
- **Config restarts**: LiteLLM and llama-swap only read config at start — after `chezmoi apply` changes a config, `systemctl --user restart llama-swap litellm` or the old routing stays live (bit us: litellm kept routing haiku to a dead per-worker port).
- **Retired-unit removal fights masks**: run_onchange masks retired units (symlink → /dev/null at the same target path), and the *next* apply's `.chezmoiremove` sweeps the mask — but a non-TTY `chezmoi apply` then prompts on the "modified" symlink. Use `chezmoi apply --force` (as `.sync` does).
- **iGPU prefill decays with context** (73→23 t/s by 10k tokens; a full 32k prompt can prefill 20+ min). Keep contexts tight; relevant to any future healthcheck that drives a real completion through a pool model — that's why `healthcheck.sh` uses a registered-probe (model listed on `:9000/v1/models`) for pool rows instead of completions.

- **ManagedOOM kill policy is a two-repo pairing (2026-07-08 livelock)**: `llama-swap.service` sets `ManagedOOMMemoryPressure=kill` / `ManagedOOMMemoryPressureLimit=60%` / `ManagedOOMSwap=kill` ("LLM stack dies first"), but these are **inert until `systemd-oomd` is installed and running** — that install lives in the crabbot repo (`cluster/thrash-protection.sh`, run with sudo), not here. Backstory: the 2026-07-04 OOM protections (score adjusts + slice caps) *prevented* kernel OOM kills so well that a 59G-host memory squeeze became a 7.5-hour unattributable page-cache-thrash livelock (1.2 GB/s reads, 83% iowait, load 130, no OOM) instead of a quick kill — PSI-based killing via oomd is the fix, MemAvailable-based killers (earlyoom) would not have fired. Full incident: crabbot `cluster/recovery.md` § "host PSI livelock". Verify live: `systemctl --user show llama-swap.service -p ManagedOOMMemoryPressure` (expect `kill`) and `systemctl is-active systemd-oomd`.

## Why opt-in and gated

The stack is heavy (models + built llama.cpp + lemonade) and machine-specific, so it must never deploy by accident on a fresh box. It's gated by the chezmoi `localLLM` flag (`.chezmoi.toml.tmpl`): `dots sync` prompts *"Manage local LLM stack on this machine?"* on first init (persisted to `~/.config/chezmoi/chezmoi.toml`; re-prompt by deleting that file). When off, `.chezmoiignore` skips the whole tree so nothing deploys.

## Managed (in-repo) vs. runtime (not managed)

The split exists so secrets and giant binaries stay off the repo while the *wiring* is reproducible.

**Managed (chezmoi sources):**

- `chezmoi/local-llm/configs/{llama-swap,litellm}.yaml` → `~/local-llm/configs/` (backend cmds + groups; proxy routing + fallbacks).
- `chezmoi/local-llm/scripts/executable_{aliases,install-npu,install-llama-swap,healthcheck,download-models}.sh` → `~/local-llm/scripts/` (the `executable_` prefix is stripped on render).
- `chezmoi/dot_config/systemd/user/{llama-swap,litellm,local-llm.target,worker-npu}` → `~/.config/systemd/user/` (verbatim; `%h`-portable, no secrets). Unit *files* only — enablement stays a runtime action. `.chezmoiremove` deletes the retired worker units on flag-on machines.

**Not managed (runtime / prerequisites):** `~/local-llm/models/`, the built `~/local-llm/bin/llama.cpp` + lemonade (manual per README), the pinned `~/local-llm/bin/llama-swap` (via `install-llama-swap.sh` / `llm-install-swap`), `~/local-llm/logs/`, and the `~/.local/bin/litellm` install. The sync never auto-enables or starts the stack — that stays explicit (`llm-up`).

## Commands

Aliases from `scripts/aliases.sh`. These require a one-time manual `echo 'source ~/local-llm/scripts/aliases.sh' >> ~/.zshrc` (per `local-llm/README.md`) — the managed `zshrc` does not source them, mirroring how `bin/` and the litellm install are manual prerequisites.

- `llm-up` / `llm-down` / `llm-status` — start/stop/inspect via systemd.
- `llm-loaded` / `llm-unload` — llama-swap resident-model state (`GET /running`) and manual unload (`POST /api/models/unload`).
- `llm-test` (= `healthcheck.sh`) — smoke test: LiteLLM, llama-swap, one real `local-haiku` completion, and `local-embed` registration must pass; pool tiers use registration probes to avoid a cold swap.
- `llm-download` (= `download-models.sh`) — on-demand, idempotent GGUF fetch (skips present files). Never run by sync.
- `llm-install-swap` (= `install-llama-swap.sh`) — pinned llama-swap release install, version-stamp idempotent.
- `dots doctor` runs `healthcheck.sh --quiet` automatically when the stack is deployed (presence-gated on `~/local-llm/scripts/healthcheck.sh`).

## Adding / tuning a model

Add the model to `llama-swap.yaml` and its group, add the LiteLLM route, add the GGUF to `download-models.sh`, apply chezmoi, restart `llama-swap` and `litellm`, then run `llm-test`. `tests/local-llm.bats` pins the config and retirement guards.

> Gotcha: the three unsloth Qwen3 repo IDs in `download-models.sh` (sonnet/haiku/coder) are **unverified** — they follow the unsloth `<Model>-GGUF` convention but weren't recorded on the source machine. The embed/vision entries are `confirmed` (HF API tree listing, 2026-06-12). Confirm unverified repos on huggingface.co before a fresh-machine download (`hf download` fails loud on a wrong repo).
