# OMP agent model and effort routing

Astra is the high tier, Sol is the medium tier, and Luna is the cheap tier.
Terra is retired from active dotfiles configuration.
This policy records the user's September 28, 2026 decision, not a permanent vendor model ranking.[^1]

## Workload policy

| Canonical agents | Codex model | Codex effort | OMP thinking |
|---|---|---|---|
| `reviewer` | GPT-6 Astra | `high` | `xhigh` |
| `judge` | GPT-6 Astra | `high` | `high` |
| `ghostbuster`, `researcher` | GPT-6 Sol | `medium` | `high` |
| `taste-tester` | GPT-6 Sol | `medium` | `medium` |
| `generalist`, `coder` | GPT-6 Sol | `medium` | `xhigh` |
| `explorer` | GPT-6 Sol | `medium` | `high` |
| `roquefort-wrecker` | GPT-6 Luna | `medium` | `xhigh` |
| `nih-scanner` | GPT-6 Luna | `medium` | `medium` |
| `duckdb-expert`, `whey-drainer`, `worktree-content-digest` | GPT-6 Luna | `low` | `low` |

Coder and explorer use Sol because their role contracts require medium capability.
Mechanical test execution and structural scans retain Luna.
Reviewers use Astra; checklist taste-tests use Sol.[^1]

`cheese-reviewer` remains OMP-only and uses `@strong` with `xhigh` thinking.[^2]
OMP thinking levels remain independent from Claude and Codex effort.

## Harness ownership

- `agents/registry.yaml:models.codex` owns each canonical Codex model.
- Registry `effort` owns Claude and Codex effort.
- Both Codex renderers emit `model_reasoning_effort` when registry effort exists.
- An agent without registry effort leaves the Codex setting absent.
- OMP-native agent files own their `thinkingLevel`; renderers do not copy registry effort into them.[^1][^3]

Explicit Codex effort prevents a medium worker from depending on the parent's reasoning setting.
Previously, both renderers copied the model but dropped effort.[^3]

OMP aliases map `strong` to Astra, `balanced` to Sol, and `fast` to Luna.
The interactive default is `@balanced:medium`; `task` uses `@balanced`.
Coder and explorer use `@balanced`.
The tight profile also uses Sol at medium effort.[^4]

## Verification

Model-policy tests lock the Claude effort mapping and the Codex workload matrix.
Renderer tests check present and absent Codex effort.
OMP tests separately check aliases and thinking levels.[^2][^3]

See [[agents-dir]] and [[subagent-routing-policy]] for dispatch rules.

[^1]: `agents/registry.yaml`; `tests/agent-skill-model-effort.bats`
[^2]: `tests/omp-agents.bats`; `chezmoi/dot_omp/private_agent/agents/cheese-reviewer.md`
[^3]: `.sync-lib.sh:_cz_render_codex_agent`; `agent-profile/agent_profile/renderers/codex.py:CodexRenderer._write_agents`; `agent-profile/tests/test_renderer_agents.py`; `tests/sync-codex-sources.bats`
[^4]: `chezmoi/.chezmoidata/omp.yaml`; `chezmoi/private_dot_omp-tight/agent/config.yml`; `tests/omp-config.bats`
