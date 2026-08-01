# OMP agent model and effort routing

Canonical agents choose the GPT-5.6 capability tier from workload breadth and stakes, then choose effort independently from reasoning demand. Do not derive effort from the model tier or derive the Codex model from the Claude model.[^1]

## Workload policy

| Canonical agents | Codex model | Effort | Rationale |
|---|---|---|---|
| `fromage-age-arch`, `fromage-secaudit`, `reviewer` | GPT-5.6 Sol | `xhigh` | Quality-first architecture, security, and final review |
| `ghostbuster`, `ricotta-reducer`, `researcher` | GPT-5.6 Terra | `high` | Broad evidence synthesis with bounded output |
| `generalist` | GPT-5.6 Terra | `xhigh` | Open-ended mixed work needs more reasoning than a focused specialist |
| `fromage-fort`, `roquefort-wrecker`, `coder` | GPT-5.6 Luna | `xhigh` | Bounded write tasks benefit from the high-volume tier plus deep reasoning |
| `explorer` | GPT-5.6 Luna | `high` | High-volume local inspection with concise synthesis |
| `nih-scanner` | GPT-5.6 Luna | `medium` | Structural candidate collection without final judgment |
| `fromage-age-history`, `duckdb-expert`, `whey-drainer`, `worktree-content-digest` | GPT-5.6 Luna | `low` | Mechanical execution and compression |

`cheese-reviewer` is OMP-only rather than canonical; it mirrors the final reviewer at `@strong`/`xhigh`.[^2]

## Why model and effort are independent

OpenAI describes Sol as the frontier tier, Terra as the intelligence/cost balance, and Luna as the efficient high-volume tier. The same guidance says to set reasoning effort independently and supports `none`, `low`, `medium`, `high`, `xhigh`, and `max` across GPT-5.6.[^1]

OMP accepts `thinkingLevel` through `xhigh` and maps it to provider-facing reasoning effort. Its model-role aliases may also carry a thinking suffix.[^3] Claude Code likewise accepts `xhigh` in skill and subagent frontmatter on current supported models, so the shared registry `effort` field can express this policy without a harness-specific workaround.[^4]

## Enforcement

`agents/registry.yaml` owns canonical model and effort metadata. OMP-native agent files mirror it because OMP does not consume the cross-harness renderer directly. `tests/agent-skill-model-effort.bats` locks the workload matrix, while `tests/omp-agents.bats` locks registry-to-OMP parity.[^2]

Selected Claude skills keep their prior uniform tier-to-effort rule and continue to reserve `xhigh`/`max` for manual use. The workload-specific exception applies to agents only.[^2]

[^1]: <https://developers.openai.com/api/docs/guides/latest-model>
[^2]: `agents/registry.yaml:23-371`, `tests/agent-skill-model-effort.bats:26-60`, `tests/omp-agents.bats:39-56`, `chezmoi/dot_omp/private_agent/agents/cheese-reviewer.md:1-7`
[^3]: <https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md>, <https://github.com/can1357/oh-my-pi/blob/main/docs/models.md>
[^4]: <https://code.claude.com/docs/en/model-config>
