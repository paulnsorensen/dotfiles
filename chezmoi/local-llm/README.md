# Local LLM stack — `~/local-llm/`

Worker-pool architecture behind a frontier reasoning agent. All endpoints OpenAI-compatible.

## Topology

```
  NPU  (XDNA 2)   :8000  local-classifier   Llama 3.2 3B INT4 (FastFlowLM, optional)
  iGPU (890M)     :8080  local-sonnet       Qwen3-30B-A3B-Instruct-2507 Q4_K_M (Vulkan)
  CPU  (Zen 5c)   :8081  local-haiku        Qwen3-8B Q4_K_M (--reasoning off)
  iGPU (890M)     :8085  local-coder        Qwen3-Coder-30B-A3B-Instruct Q4 (optional, displaces Sonnet)
  iGPU (890M)     :8090  local-opus         Llama 3.3 70B Q4 (optional, displaces Sonnet)
  CPU  (Zen 5c)   :8082  local-vision      Qwen2.5-VL-7B Q4 (optional)
                  :4000  LiteLLM proxy      unified front; fallbacks configured
```

## Quick start

```bash
# Source aliases (once):
echo 'source ~/local-llm/scripts/aliases.sh' >> ~/.zshrc

# Always-on stack auto-starts on login (linger enabled, default.target):
llm-status                       # check what's up
llm-ping                         # quick port probe
llm-models                       # list models LiteLLM serves
llm-chat local-sonnet "hello"    # one-shot chat

# Optional tiers:
llm-coder-on                     # Qwen3-Coder-30B-A3B, auto-stops Sonnet
llm-coder-off                    # back to Sonnet
llm-opus-on                      # 70B, auto-stops Sonnet
llm-opus-off                     # back to Sonnet
llm-vision-on                    # adds vision worker on CPU
llm-vision-off

# NPU (needs sudo block first):
bash ~/local-llm/scripts/install-npu.sh
llm-npu-on
```

## Resource budget

| State | Resident | Peak bandwidth (~120 GB/s avail) |
|---|---|---|
| Always-on only (Sonnet + Haiku + LiteLLM) | ~23 GB | ~70 GB/s |
| + NPU classifier | ~25 GB | ~73 GB/s |
| + Vision (CPU) | ~28 GB | ~80 GB/s |
| Opus mode (Sonnet stopped, 70B running) | ~45 GB | ~70 GB/s |

## Layout

```
~/local-llm/
├── bin/
│   ├── llama.cpp/         # Vulkan-build llama-server (b9391)
│   └── lemonade/          # Lemonade Server v10.6.0 (NPU)
├── configs/
│   └── litellm.yaml
├── logs/                  # all worker + LiteLLM logs
├── models/
│   ├── Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf
│   └── Qwen3-8B-Q4_K_M.gguf
├── scripts/
│   ├── aliases.sh
│   └── install-npu.sh
└── systemd/               # (unit files actually live in ~/.config/systemd/user/)
```

## Frontier agent integration

```python
# OpenAI-compatible client pointed at LiteLLM:
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:4000/v1", api_key="sk-local")

# Use model names by tier:
resp = client.chat.completions.create(
    model="local-sonnet",            # main worker
    # model="local-haiku",           # cheap/fast
    # model="local-classifier",      # tiny/NPU (falls back to haiku if NPU off)
    # model="local-opus",            # 70B (falls back to sonnet if not running)
    # model="local-vision",          # VLM (no fallback)
    messages=[{"role": "user", "content": "..."}],
)
```

## Fallbacks (in `litellm.yaml`)

- `local-opus` → `local-sonnet`
- `local-classifier` → `local-haiku`
- `local-vision` → no fallback (fails loudly so the agent can adapt)

## Adding the optional models

```bash
# Opus — Llama 3.3 70B Q4_K_M (42.52 GB):
hf download unsloth/Llama-3.3-70B-Instruct-GGUF \
  Llama-3.3-70B-Instruct-Q4_K_M.gguf --local-dir ~/local-llm/models

# Vision — Qwen2.5-VL-7B + mmproj (5.53 GB total, ggml-org = llama.cpp team's official repo):
hf download ggml-org/Qwen2.5-VL-7B-Instruct-GGUF \
  Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf --local-dir ~/local-llm/models
hf download ggml-org/Qwen2.5-VL-7B-Instruct-GGUF \
  mmproj-Qwen2.5-VL-7B-Instruct-Q8_0.gguf --local-dir ~/local-llm/models
```

The systemd units gate on file presence (`ConditionPathExists=`), so once the file is there, the unit starts cleanly.

## Tuning notes

- iGPU worker `--ctx-size 32768 --parallel 8` → 4096 tokens/slot. Increase for long-context tasks; decrease parallelism to give each slot more.
- CPU worker pinned to Zen 5c efficiency cores (4-11, 16-23) to leave Zen 5 perf cores free for foreground work.
- KV cache quantized to Q8_0 on Sonnet + Opus (`--cache-type-k q8_0 --cache-type-v q8_0`) — halves KV memory.
- All workers run with `Nice` ≥ 5 so foreground work isn't crushed.
