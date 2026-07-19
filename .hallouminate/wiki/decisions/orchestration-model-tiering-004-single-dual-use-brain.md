# ADR orchestration-model-tiering-004: One dual-use brain definition  [status: accepted]

- **Context:** The fable brain is needed on two invocation paths: direct Agent-tool dispatch from the Sonnet top (brain-and-hands) and as plan/judge stages inside the default pipeline (Workflow `agentType`). Candidates: one shared agent definition, or two specialized ones.
- **Decision:** A single `deep-thinker` definition (name is a placeholder) serves both paths — `model: fable`, `effort: xhigh`, read-only tool surface, a goal-and-constraints prompt kept deliberately un-prescriptive (Fable documentation warns that over-prescriptive prompts written for prior models reduce its output quality).
- **Alternatives:** Separate "planner" and "judge" definitions allow role-tuned prompts but guarantee divergence of two expensive prompts that encode the same brain contract; role context rides in the dispatch prompt instead.
- **Consequences:** One place to tune the brain; the role is supplied per-dispatch. A dispatched brain cannot fan out (one-level nesting — dispatched agents have no Agent tool), which is fine by design: it returns a plan and either the Sonnet top or the workflow script does the spinning-off.

Related: [[decisions/orchestration-model-tiering-001-fable-brains-only]], [[decisions/orchestration-model-tiering-003-routing-ladder-standing-auth]]
