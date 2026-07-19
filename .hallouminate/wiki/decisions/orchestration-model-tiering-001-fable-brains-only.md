# ADR orchestration-model-tiering-001: Fable as the brain tier only, pinned xhigh  [status: accepted]

- **Context:** Moving off a flagship-at-the-top design, the deep-reasoning tier had to land somewhere. `claude-fable-5` is the tier above Opus ($10/$50 vs $5/$25 per MTok) and the user suspects Opus quality degradation. Candidates: fable everywhere the design said opus/xhigh (brains + review gates), fable for brains only, or fable strictly on-demand.
- **Decision:** Fable for the reasoning brains only — the `deep-thinker` agent and the plan/judge stages of the default pipeline — pinned `model: fable`, `effort: xhigh` in frontmatter. Review gates (reviewer/fromage-secaudit/fromage-age-arch) stay pinned opus/high.
- **Alternatives:** Fable-everywhere doubles gate cost for review work opus handles well; on-demand-only re-introduces per-use friction that the ambient-flagship design was already paying in reverse. The frontmatter `xhigh` pin (vs workflow-only effort) is what makes fable/xhigh reachable via the plain Agent tool, which has no effort parameter.
- **Consequences:** Deep reasoning costs are deliberate and legible (one brain dispatch or pipeline stage at a time); gates stay at half the token price. Fable brain turns can run minutes at xhigh — the routing rule must keep trivia away from them.

Related: [[decisions/orchestration-model-tiering-002-sonnet-top-both-paths]], [[decisions/orchestration-model-tiering-003-routing-ladder-standing-auth]]
