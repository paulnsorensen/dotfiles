# OMP agent model and effort routing

Canonical agents choose their Codex GPT-5.6 model by workload, while each OMP-native agent chooses `thinkingLevel` independently. Registry `effort` remains Claude-specific and follows the established Claude tier policy: Haiku `low`, Sonnet `medium`, Opus `high`. Never mirror registry `effort` into OMP frontmatter.[^1]

## Workload policy

| Canonical agents | Codex model | OMP thinking | Rationale |
|---|---|---|---|
| `reviewer` | GPT-5.6 Sol | `xhigh` | Quality-first final review |
| `ghostbuster`, `researcher` | GPT-5.6 Terra | `high` | Broad evidence synthesis with bounded output |
| `generalist` | GPT-5.6 Terra | `xhigh` | Open-ended mixed work needs deeper reasoning |
| `roquefort-wrecker`, `coder` | GPT-5.6 Luna | `xhigh` | Bounded write tasks pair the high-volume tier with deep reasoning |
| `explorer` | GPT-5.6 Luna | `high` | High-volume local inspection with concise synthesis |
| `nih-scanner` | GPT-5.6 Luna | `medium` | Structural candidate collection without final judgment |
| `duckdb-expert`, `whey-drainer`, `worktree-content-digest` | GPT-5.6 Luna | `low` | Mechanical execution and compression |

`cheese-reviewer` is OMP-only rather than canonical; it mirrors the final reviewer at `@strong`/`xhigh`.[^2]

The retired `fromage-age-arch`, `fromage-age-history`, `fromage-fort`, `fromage-secaudit`, and `ricotta-reducer` agents have no canonical registrations or OMP-native copies. Their removal and replacement paths are documented in [[agent-vs-skill-tiering]].[^3]

## Harness ownership

- `agents/registry.yaml:models.codex` records the workload-specific Codex family. OMP-native files express that family through `@strong`, `@balanced`, or `@fast` aliases.[^1]
- `agents/registry.yaml:effort` is a Claude-honored field. It stays coupled to `models.claude`, not to the Codex family or OMP thinking.[^1]
- `chezmoi/dot_omp/private_agent/agents/*.md:thinkingLevel` owns OMP reasoning depth. Its value follows the workload table above.[^2]

OpenAI describes Sol as the frontier tier, Terra as the intelligence/cost balance, and Luna as the efficient high-volume tier. Reasoning effort is a separate setting.[^4] OMP accepts `thinkingLevel` through `xhigh` and supports model-role aliases, including aliases with thinking suffixes.[^5]

## Enforcement

`tests/agent-skill-model-effort.bats` locks Claude tier-to-effort policy and the workload-specific `models.codex` matrix. `tests/omp-agents.bats` separately locks the exact OMP agent inventory, model aliases, and `thinkingLevel` values.[^2]

[^1]: `agents/registry.yaml:11-12`, `agents/registry.yaml:23-267`
[^2]: `tests/agent-skill-model-effort.bats:1-117`, `tests/omp-agents.bats:8-130`, `chezmoi/dot_omp/private_agent/agents/cheese-reviewer.md:1-7`
[^3]: `agents/registry.yaml:23-267`, `chezmoi/dot_omp/private_agent/agents/`
[^4]: <https://developers.openai.com/api/docs/guides/latest-model>
[^5]: <https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md>, <https://github.com/can1357/oh-my-pi/blob/main/docs/models.md>
