# Domain model

Cumulative ubiquitous language for this repo's agent-orchestration domain. Merged per-session at curdle; context-specific terms only.

**Top** — the interactive top-level orchestrator model+effort a session boots with; two launch paths set it independently (terminal settings floor, Conductor app preference).
_Avoid_: orchestrator model, apex
_Code_: chezmoi/lib/claude-settings-authoritative.json:1-2 (terminal, claude-sonnet-5[1m]/high); Conductor app pref (manual)

**Brain** — a Fable/xhigh reasoning delegate that returns decisions and plans; read-only, never edits, never fans out.
_Avoid_: god-tier agent, planner agent
_Code_: agents/registry.yaml (`deep-thinker` entry) + agents/agent_definitions/deep-thinker.md

**Brain-and-hands** — delegation pattern: the brain reasons and returns a plan; the Sonnet top performs the dispatch/fan-out and owns the human channel.
_Code_: agents/preamble.md (Model-tier routing ladder, rung 2)

**Default pipeline** — the named workflow the top invokes for multi-step work: Fable Plan stage → cheap Work fan-out → Fable Judge stage.
_Avoid_: default workflow
_Code_: claude/workflows/default-pipeline.js

**Three-rung ladder** — standing routing rule: trivial → inline; single hard question → brain dispatch; multi-step/decomposable → default pipeline (standing Workflow authorization).
_Avoid_: routing ladder
_Code_: agents/preamble.md (Model-tier routing ladder)

**Backbone** — the phase agents (explorer/researcher/coder/generalist) that cascade with the session via `model: inherit`, no effort key.
_Avoid_: phase backbone
_Code_: agents/registry.yaml

**Gates** — quality-gate agents pinned opus/high (reviewer, fromage-secaudit, fromage-age-arch); must never downgrade in a lean session.
_Avoid_: review agents
_Code_: agents/registry.yaml

**Workers** — mechanical agents pinned haiku/low (whey-drainer, duckdb-expert, fromage-age-history, worktree-content-digest); must never upgrade in a deep session.
_Code_: agents/registry.yaml
