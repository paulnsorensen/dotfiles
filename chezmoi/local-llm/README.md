# Local LLM stack — `~/local-llm/`

On-demand serving behind a frontier reasoning agent: llama-swap loads and
unloads llama-server backends as requests arrive. All endpoints OpenAI-compatible.

## Topology

```
  llama-swap (:9000) — routes by model name, swaps backends on demand:
    hot   local-haiku    Qwen3-8B Q4_K_M (CPU taskset, always resident)
    hot   local-embed    Qwen3-Embedding-0.6B Q8_0 (CPU, always resident)
    pool  local-sonnet   Qwen3-30B-A3B-Instruct-2507 Q4_K_M (iGPU Vulkan) ┐
    pool  local-coder    Qwen3-Coder-30B-A3B-Instruct Q4 (iGPU)           ├ one at a time
    pool  local-vision   Qwen3-VL-8B Q4_K_M (CPU)                         ┘
  worker-npu  (XDNA 2)  :8000  local-classifier  Llama 3.2 3B INT4 (FastFlowLM, optional)
                        :4000  LiteLLM proxy     unified front; fallbacks configured

  No opus tier: dense-70B is bandwidth-capped to ~2 t/s on this box (#289) —
  opus-grade work routes to cloud models.
```

Swap-pool models unload after 10 min idle (`globalTTL: 600`; coder keeps a
longer 15 min `ttl`). A cold load is held open by llama-swap — the request
waits (up to `healthCheckTimeout: 360`) instead of getting a 503.

## Quick start

```bash
# One-time: install the pinned llama-swap binary (llama.cpp is built per below):
bash ~/local-llm/scripts/install-llama-swap.sh

# Source aliases (once):
echo 'source ~/local-llm/scripts/aliases.sh' >> ~/.zshrc

# Stack auto-starts on login (linger enabled, default.target):
llm-status                       # check what's up
llm-ping                         # quick port probe (4000/9000/8000)
llm-models                       # list models LiteLLM serves
llm-loaded                       # which backends llama-swap has resident
llm-unload                       # manually unload all swap-pool backends
llm-chat local-sonnet "hello"    # one-shot chat (cold-loads sonnet if needed)

# Optional tiers (separate units):
bash ~/local-llm/scripts/install-npu.sh   # NPU needs sudo block first
llm-npu-on
```

## Resource budget

| State | Resident | Notes |
|---|---|---|
| Idle (hot group + proxies) | ~8 GB | haiku + llama-swap + LiteLLM |
| + one swapped 30B (sonnet/coder) | ~28 GB | unloads after TTL |
| + NPU classifier | +2 GB | separate unit |
| + vision (Qwen3-VL-8B, CPU) | ~6 GB | swap pool |

`llama-swap.service` carries `MemoryMax=30G` — hot group + one swapped model +
headroom — with the same bounded-restart hardening as #287.

## Layout

```
~/local-llm/
├── bin/
│   ├── llama.cpp/         # Vulkan-build llama-server (b9391, built manually)
│   ├── llama-swap         # pinned release binary (install-llama-swap.sh)
│   └── lemonade/          # Lemonade Server v10.6.0 (NPU)
├── configs/
│   ├── llama-swap.yaml       # backend cmds + hot/pool groups + TTLs
│   ├── litellm.yaml
│   └── lean.json             # opencode MCP overlay (see "Lean opencode runs" below)
├── logs/                  # llama-swap (incl. backend output) + LiteLLM logs
├── models/
├── scripts/
│   ├── aliases.sh
│   ├── install-llama-swap.sh
│   ├── download-models.sh
│   ├── healthcheck.sh
│   └── install-npu.sh
└── systemd/               # (unit files actually live in ~/.config/systemd/user/)
```

## Frontier agent integration

```python
# OpenAI-compatible client pointed at LiteLLM:
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:4000/v1", api_key="sk-local")

# Use model names by tier — llama-swap cold-loads pool models on first use:
resp = client.chat.completions.create(
    model="local-sonnet",            # main worker (swap pool)
    # model="local-haiku",           # cheap/fast (always resident)
    # model="local-coder",           # code (swap pool, displaces sonnet)
    # model="local-classifier",      # tiny/NPU (falls back to haiku if NPU off)
    # model="local-embed",           # embeddings (always resident, /v1/embeddings)
    # model="local-vision",          # VLM (swap pool)
    messages=[{"role": "user", "content": "..."}],
)
```

## Lean opencode runs (fits the 32k `local-coder` window)

opencode eager-loads every MCP tool schema into the prompt on every request, so
the default MCP set crowds out the 32k window `local-coder` runs in. `configs/lean.json`
is an `OPENCODE_CONFIG` overlay that disables the heavy non-coding servers
(`hallouminate`, `tavily`), keeping `tilth` + `serena` +
`context7` for the coder.

```bash
opencode-lean --model local-coder      # OPENCODE_CONFIG=~/local-llm/configs/lean.json opencode
```

`OPENCODE_CONFIG` mergeDeeps onto the global `opencode.json` — the overlay is just the
`enabled: false` lines, not a from-scratch config. Disabling a server is the only lever
that stops schema injection; per-agent `tools:{x:false}` gates execution but still ships
the schema tokens. (Todoist is already disabled globally, so the overlay omits it.)

## Fallbacks (in `litellm.yaml`)

- `local-classifier` → `local-haiku`
- Pool models need no fallback — llama-swap cold-loads them on demand.

## Models

All portfolio weights come from `llm-download` (`scripts/download-models.sh`);
the embed + vision repo IDs are confirmed against huggingface.co (official
Qwen GGUF repos). llama-swap registers every configured model regardless of
file presence; a missing GGUF only fails when that model is first requested.
`worker-npu` still gates on `ConditionPathExists=`.

## Tuning notes

- Swap-pool sizing: `llama-swap.yaml` group `pool` is strict one-at-a-time
  (`swap: true, exclusive: true`). Loosen later if RAM allows vision + sonnet.
- CPU models pinned to Zen 5c efficiency cores (haiku 4-11,16-23; vision
  8-11,20-23) to leave Zen 5 perf cores free for foreground work.
- KV cache quantized to Q8_0 on the 30B pool models — halves KV memory.
- iGPU prefill decays with context (73→23 t/s by 10k tokens) — a full 32k
  prompt can take 20+ min to prefill; keep contexts tight.
