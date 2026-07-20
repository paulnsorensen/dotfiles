---
status: reviewed
last_verified: 2026-07-20
confidence: medium
sources:
  - omp://tools/task.md
  - omp://settings.md
  - omp://models.md
  - https://openrouter.ai/api/v1/models
  - https://openrouter.ai/api/frontend/v1/rankings/models?view=week
---
# OMP fan-out and worker models

OMP fan-out cost is controlled by two separate levers: task runtime policy decides how many workers can spawn, and `modelRoles.task` / `modelRoles.smol` / `modelRoles.tiny` decide how expensive those workers are. Keep deep models on parent roles (`plan`, `slow`, explicit `/model`) and put cheap models on spawned-worker roles.

## Current risk profile

Observed on 2026-07-20 with `rtk omp config get/list` in this repo:

| Setting | Observed value | Cost implication |
| --- | ---: | --- |
| `tools.approvalMode` | `yolo` | Tool calls do not stop for confirmation by default. |
| `tools.approval` | `{}` | No explicit `task` approval override. |
| `async.enabled` | `true` | Fan-outs can run in the background and become easy to miss. |
| `task.batch` | `true` | One call can launch many subagents. |
| `task.maxConcurrency` | `32` | Up to 32 subagents can run at once. |
| `task.maxRecursionDepth` | `2` | Children can still spawn grandchildren. |
| `task.softRequestBudget` | `200` | Subagents are not strongly budget-steered. |
| `task.maxRuntimeMs` | `0` | No configured wall-clock cap. |

This is the dangerous combination: `plan` or `slow` on an expensive reasoning model plus permissive task fan-out can burn a weekly subscription or OpenRouter balance without any single worker looking excessive.

## Budget guardrail profile

Use this shape in the managed chezmoi OMP config, not by hand-editing live generated config:

```yaml
omp:
  config:
    async:
      enabled: false        # optional: background work becomes visible/blocking

    tools:
      approval:
        task: prompt        # approve each subagent fan-out even in yolo mode

    task:
      eager: default        # lowest documented eagerness mode: default/preferred/always
      batch: false          # prevents one Task call from launching N workers
      maxConcurrency: 2     # hard cap live subagents
      maxRecursionDepth: 1  # children cannot spawn grandchildren
      softRequestBudget: 30 # steer workers to wrap up
      maxRuntimeMs: 600000  # 10 minute hard cap per worker
```

For a hard no-fanout session, set `tools.approval.task: deny`. To keep specialist agents but remove the generic catch-all worker, add `task.disabledAgents: [task]`.

## Role split

Keep parent reasoning and worker execution on different price tiers:

```yaml
modelRoles:
  default: openai-codex/gpt-5.6-terra:medium
  plan: openai-codex/gpt-5.6-sol:xhigh
  slow: openai-codex/gpt-5.6-sol:xhigh

  # spawned-worker roles
  task: openrouter/deepseek/deepseek-v4-flash
  smol: openrouter/qwen/qwen3-coder-30b-a3b-instruct
  tiny: openrouter/mistralai/mistral-nemo
  commit: openrouter/openai/gpt-5-nano

  # explicit escalation, not fan-out default
  advisor: openrouter/moonshotai/kimi-k3
```

The invariant is simple: `plan` / `slow` may be expensive because the parent is visible; `task` / `smol` / `tiny` / `commit` must be cheap because fan-out multiplies them.

## OpenRouter worker candidates

Prices and capabilities below came from OpenRouter's live `/api/v1/models` on 2026-07-20. The blended price is a 10 input : 1 output token mix, which matches many code-review/search workers better than chatty assistant usage.

| Worker type | Recommended model | Context | Price in/out per 1M | 10:1 blend | Signal | Caveat |
| --- | --- | ---: | ---: | ---: | --- | --- |
| Default coder worker | `openrouter/deepseek/deepseek-v4-flash` | 1,048,576 | `$0.098 / $0.196` | `$0.107` | Tools, structured outputs, coding 56.2, agentic 31.1, 18 endpoints. | Reasoning defaults to high where supported; use only if OMP/provider handling does not leak expensive reasoning tokens. |
| Cheap coder worker | `openrouter/qwen/qwen3-coder-30b-a3b-instruct` | 160,000 | `$0.07 / $0.27` | `$0.088` | Coder-branded, tools, structured outputs, 5 endpoints. | No OpenRouter Artificial Analysis coding index in the model API snapshot. |
| Long-context cheap worker | `openrouter/qwen/qwen3.5-flash-02-23` | 1,000,000 | `$0.065 / $0.26` | `$0.083` | Tools, structured outputs, very cheap 1M context. | Single provider in the endpoint snapshot. |
| Ultra-cheap menial worker | `openrouter/mistralai/mistral-nemo` | 131,072 | `$0.019 / $0.03` | `$0.020` | Tools, structured outputs, multiple endpoints. | Use for summarization, routing, classification, and small edits, not hard debugging. |
| Strong cheap contender | `openrouter/tencent/hy3-preview` | 262,144 | `$0.063 / $0.21` | `$0.076` | Coding 58.8, agentic 30.7, OpenRouter weekly usage leader. | No structured-output support in the model API snapshot; preview model. |
| Strong cheap contender | `openrouter/xiaomi/mimo-v2.5` | 1,048,576 | `$0.14 / $0.28` | `$0.153` | Tools, structured outputs, coding 56.8. | Endpoint uptime snapshot was lower than DeepSeek/Qwen/Mistral. |
| Commit / tiny fallback | `openrouter/openai/gpt-5-nano` | 400,000 | `$0.05 / $0.40` | `$0.082` | Tools, structured outputs, familiar OpenAI behavior. | Output is more expensive than Qwen/DeepSeek; reasoning is mandatory. |
| Free disposable worker | `openrouter/google/gemma-4-31b-it:free` | 262,144 | `$0 / $0` | `$0` | Tools, structured outputs, coding 43.4. | Free pools can rate-limit or disappear; do not use for critical writes. |
| Free coding experiment | `openrouter/qwen/qwen3-coder:free` | 1,048,576 | `$0 / $0` | `$0` | Coder-branded, tools, 1M context. | No structured-output support or benchmark fields in the snapshot. |
| Free long-context experiment | `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free` | 1,000,000 | `$0 / $0` | `$0` | Coding 49.3, agentic 27.4, tools. | Reasoning defaults high; no structured-output support in the snapshot. |

## Fastest is not directly measured here

OpenRouter's public model and endpoint APIs exposed price, context, supported parameters, benchmark fields, endpoint counts, and uptime for the candidates above. The endpoint records did not expose non-null latency or throughput for this shortlist at capture time, so “fastest” is an inference from `flash`/`preview` model class, endpoint count, weekly usage, and price. Treat the speed ranking as provisional until measured with the local OMP workload.

Practical starting order for simple coder workers:

1. `deepseek/deepseek-v4-flash` for default `task`: best cheap balance of context, tool support, structured outputs, benchmark signal, and endpoint diversity.
2. `qwen/qwen3-coder-30b-a3b-instruct` for `smol`: cheap code-specialist worker when 160k context is enough.
3. `mistralai/mistral-nemo` for `tiny`: cheapest useful menial agent for read-only triage, summaries, and simple mechanical edits.
4. `tencent/hy3-preview` as a benchmark watchlist candidate: excellent cheap coding signal and weekly usage, but preview status and no structured-output support make it riskier as a default worker.
5. `xiaomi/mimo-v2.5` as a long-context alternative: good coding signal and structured outputs, but less compelling uptime in the endpoint snapshot.

## Kimi K3 placement

`moonshotai/kimi-k3` is not a fan-out default. It is expensive (`$3 / $15` per 1M), has mandatory max-style reasoning in Moonshot docs, and had only one OpenRouter upstream provider in the checked snapshot. Keep it as an explicit escalation role such as `advisor` or manual `/model` for large-repo, visual, or long-horizon reasoning.

_Source: 2026-07-19/20 OMP + OpenRouter model-role research · Updated: 2026-07-20 · Supersedes: none_
