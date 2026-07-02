# OMP Model Routing

As of 2026-07-01, use direct `openai-codex` for the main execution lane and OpenRouter only where it buys a distinct role: cheap/fast `smol`, long-context multimodal planning/design, and cross-family advisor review. Leave `providers.openrouterVariant: default`; set `:floor`/`:exacto` on individual OpenRouter role selectors instead.

## OMP mechanics to preserve

- Built-in model roles are `default`, `smol`, `slow`, `vision`, `plan`, `designer`, `commit`, `tiny`, `task`, and `advisor` (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/model-roles.ts:8-18`, `/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/model-roles.ts:28-52`).
- `pi/<role>` expands through `modelRoles`; roles without their own default priority can alias another role (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/model-resolver.ts:814-860`).
- Role selectors can carry thinking suffixes such as `:low`, `:medium`, `:high`, or `:xhigh`; `max` aliases to `xhigh`, but `auto` is not a suffix selector (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/thinking.ts:20-46`).
- OMP settings support `modelRoles`, `modelProviderOrder`, and path-scoped `enabledModels` (`/home/paul/Dev/oh-my-pi/docs/settings.md:221-240`, `/home/paul/Dev/oh-my-pi/docs/settings.md:287-307`).
- Explicit provider/model selectors use `provider/model-id` (`/home/paul/Dev/oh-my-pi/docs/models.md:540-553`).
- `providers.openrouterVariant` accepts `default`, `nitro`, `floor`, `online`, and `exacto`; explicit selector variants override the global setting (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings-schema.ts:4643-4664`).
- `retry.fallbackChains` is a record setting, so keep fallback intent explicit per role (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/config/settings-schema.ts:1360-1370`).

## July 2026 role map

| Role | Selector | Confidence | Why |
|---|---|---|---|
| `default` | `openai-codex/gpt-5.5` | `<certain>` | OpenAI Codex docs say start with GPT-5.5 for most Codex work; OpenAI positions GPT-5.5 as strongest for coding/tool-heavy agent workflows.[^openai-codex-models][^openai-latest-model] |
| `slow` | `openai-codex/gpt-5.5:high` | `<certain>` | Same direct Codex lane, with high reasoning for complex agentic work where latency matters less.[^openai-latest-model] |
| `smol` | `openrouter/google/gemini-2.5-flash:floor:low` | `<speculative>` | Cheapest fast lane in the checked set; `:floor` biases OpenRouter to cheapest compatible upstream.[^openrouter-flash][^openrouter-floor] |
| `plan` | `openrouter/google/gemini-2.5-pro:high` | `<speculative>` | Plan mode is read/synthesis-heavy; Gemini 2.5 Pro gives 1M context and multimodal support at lower cost than GPT-5.5.[^openrouter-pro] |
| `advisor` | `openrouter/anthropic/claude-sonnet-4.5:exacto:medium` | `<speculative>` | Advisor should be a strong second-opinion lane, not the same model family as default; `:exacto` makes OpenRouter quality-biased for tool calls.[^openrouter-sonnet][^openrouter-exacto] |
| `task` | `openai-codex/gpt-5.4` | `<speculative>` | Parallel subagents multiply cost; GPT-5.4 keeps the Codex/GPT execution family at a lower price point than GPT-5.5.[^openai-pricing] |
| `vision` | `openrouter/google/gemini-2.5-pro:high` | `<speculative>` | Dedicated multimodal role; Gemini 2.5 Pro advertises broad multimodal input and long context.[^openrouter-pro] |
| `designer` | `openrouter/google/gemini-2.5-pro:medium` | `<certain>` | OMP's built-in designer priorities already favor Gemini Pro-class models, and the role emphasizes UI/UX judgment more than tool-heavy coding (`/home/paul/Dev/oh-my-pi/packages/coding-agent/src/priority.json:49-58`). |

## Recommended config

```yaml
modelRoles:
  default: "openai-codex/gpt-5.5"
  smol: "openrouter/google/gemini-2.5-flash:floor:low"
  slow: "openai-codex/gpt-5.5:high"
  plan: "openrouter/google/gemini-2.5-pro:high"
  advisor: "openrouter/anthropic/claude-sonnet-4.5:exacto:medium"
  task: "openai-codex/gpt-5.4"
  vision: "openrouter/google/gemini-2.5-pro:high"
  designer: "openrouter/google/gemini-2.5-pro:medium"

modelProviderOrder:
  - openai-codex
  - openrouter

enabledModels:
  - openai-codex/gpt-5.5
  - openai-codex/gpt-5.4
  - openai-codex/gpt-5.4-mini
  - openrouter/anthropic/claude-sonnet-4.5
  - openrouter/anthropic/claude-opus-4.1
  - openrouter/google/gemini-2.5-pro
  - openrouter/google/gemini-2.5-flash

providers:
  openrouterVariant: default

retry:
  fallbackChains:
    default:
      - openai-codex/gpt-5.4
      - openrouter/anthropic/claude-sonnet-4.5:exacto
      - openrouter/google/gemini-2.5-pro
    slow:
      - openrouter/anthropic/claude-opus-4.1:exacto:high
      - openai-codex/gpt-5.4:high
    task:
      - openai-codex/gpt-5.4-mini
      - openrouter/anthropic/claude-sonnet-4.5:exacto
    smol:
      - openai-codex/gpt-5.4-mini
    vision:
      - openai-codex/gpt-5.5
```

## OpenRouter variant rule

Use the global variant only for a coarse policy; otherwise keep it `default` and put variants on selectors. `:floor` belongs on `smol`; `:exacto` belongs on quality-sensitive OpenRouter tool roles like `advisor`; avoid global `:online` because OpenRouter documents it as deprecated in favor of web-search tooling; reserve `:nitro` for latency-over-quality sessions.[^openrouter-routing][^openrouter-auto-exacto]

_Source: OMP model-settings briesearch · Checked: 2026-07-01._

[^openai-codex-models]: OpenAI Codex models docs, retrieved 2026-07-01: <https://developers.openai.com/codex/models>
[^openai-latest-model]: OpenAI latest model migration guide, retrieved 2026-07-01: <https://developers.openai.com/api/docs/guides/latest-model>
[^openai-pricing]: OpenAI API pricing, retrieved 2026-07-01: <https://developers.openai.com/api/docs/pricing>
[^openrouter-flash]: OpenRouter Gemini 2.5 Flash page, retrieved 2026-07-01: <https://openrouter.ai/google/gemini-2.5-flash>
[^openrouter-pro]: OpenRouter Gemini 2.5 Pro page, retrieved 2026-07-01: <https://openrouter.ai/google/gemini-2.5-pro>
[^openrouter-sonnet]: OpenRouter Claude Sonnet 4.5 page, retrieved 2026-07-01: <https://openrouter.ai/anthropic/claude-sonnet-4.5>
[^openrouter-floor]: OpenRouter floor-price shortcut docs, retrieved 2026-07-01: <https://openrouter.ai/docs/guides/routing/provider-selection#floor-price-shortcut>
[^openrouter-exacto]: OpenRouter Exacto docs, retrieved 2026-07-01: <https://openrouter.ai/docs/guides/routing/model-variants/exacto>
[^openrouter-auto-exacto]: OpenRouter Auto Exacto docs, retrieved 2026-07-01: <https://openrouter.ai/docs/guides/routing/auto-exacto>
[^openrouter-routing]: OpenRouter provider routing docs, retrieved 2026-07-01: <https://openrouter.ai/docs/guides/routing/provider-selection>
