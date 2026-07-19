# ADR orchestration-model-tiering-003: Three-rung routing ladder with standing Workflow authorization  [status: accepted]

- **Context:** With a lean Sonnet top and a fable brain tier, the top needs a rule for when to reach for what — and the Workflow tool is opt-in-only by policy, so a "default pipeline the top invokes by default" needs written standing authorization or the top asks permission every time.
- **Decision:** Three-rung ladder in the preamble: trivial/conversational → inline; single hard reasoning question → dispatch `deep-thinker` via the Agent tool; multi-step or decomposable task → invoke the `default-pipeline` workflow, with the preamble text serving as standing authorization (no per-invocation ask).
- **Alternatives:** Two-rung (inline or workflow, no direct brain dispatch) pays pipeline overhead for one-shot questions; ask-first workflow invocation preserves the permission ritual at the cost of the frictionless-default goal.
- **Consequences:** The top stays the sole human channel by construction — subagents and workflow stages cannot ask the user anything, so all input flows through Sonnet, which is also the context-economics win (fable sees distilled problems, not file dumps). Risk: the "multi-step" rung may over-trigger; the wording is tunable after observation.

Related: [[decisions/orchestration-model-tiering-004-single-dual-use-brain]]
