# ADRs — subagent-routing-overhaul

Decisions behind the phase-anchored routing overhaul (spec:
`~/.local/share/cheese/paulnsorensen-dotfiles/specs/subagent-routing-overhaul.md`,
approved 2026-07-24). Dialogue provenance: `.cheese/notes/subagent-routing-overhaul.md`
(culture round 3 + mold round). Doctrine: [[architecture/subagent-routing-policy]],
[[architecture/fanout-fanin-discipline]], [[operations/prompting-claude-opus-5]],
[[architecture/knowledge-graph-playbook]].

## ADR-1: Phase-anchored sizing replaces the universal scoper  [accepted]

- Context: v1 planned a haiku scoper dispatched before every non-trivial task,
  feeding an 8-dimension score and a route enum.
- Decision: each entry point sizes its own work from evidence it already holds
  (mold: dialogue; cook: spec; age: diff; affinage: PR; pasteurize: symptom).
  Scoper deleted; verifier kept; hard risk-overrides survive as deterministic
  checks inside the gates.
- Consequence: no per-task scoping dispatch or latency; mis-sizing is caught by
  downstream gates instead of prevented up front.

## ADR-2: Curdle at spec time, via a dispatched decomposer  [accepted]

- Decision: mold dispatches the fresh-context decomposer against draft spec
  text alone; curds land in the approved artifact. Cook keeps the same
  dispatch as a fallback for un-curded specs (same schema, both doors).
- Why dispatched rather than inline: coders only ever see the spec text, so
  decomposing from the text alone doubles as a spec-completeness check.

## ADR-3: Cook is the single implementation pathway  [accepted]

- Decision: /ultracook retires as an entry point (decomposer + fanout python
  survive as internals). Cook's gate shows the wave plan ("12 ACs -> 5 curds,
  2 waves. Go?") before any fan-out; waves cap concurrency at 4; the gate
  recommends cheese-factory above 2 waves. No hard curd ceiling: magnitude is
  human-gated at mold approval and cook's gate (v1 open decision 6 resolved).

## ADR-4: Workflows are thin wrappers and live in easy-cheese  [accepted]

- Decision: no routing logic in workflow JS, ever — orchestration, barriers,
  resume, journal, and mechanical fan-in envelope validation only; every
  decision arrives as an artifact (curd block, gate output, router output).
  cheese-factory.js and age-fanout.js migrate from dotfiles claude/workflows/
  into easy-cheese workflows/ (user-directed, mold round); dotfiles keeps
  deploy wiring and move-my-cheese.
- Why: the workflow drifted from the skills once already (see the
  cheese-factory ADR-007 incident); JS cannot drift on decisions it never
  makes, and the wrappers belong beside the router and artifacts they consume.

## ADR-5: Age/affinage route deterministically to 1..N strong reviewers  [accepted]

- Decision: a pure function (easy-cheese `src/fanout/age_route.py`, unit
  tested) maps diff stat + risk flags (affinage: comments + CI class) to
  N in {1, 4, 10}, grouped lenses, and an effort dial (fast pass low/medium
  per Opus 5 review behavior). Skill path calls it inline; workflows consume
  its output as args. Replaces the split-brain (skill size-gate vs workflow
  fixed-10) and v1 open decision 3 (reversed: python, not JS or prose).

## ADR-6: Reviewer presence and grounding rules  [accepted]

- Taste-test: presence-gated, not tier-gated — 0 or 1 opus-pinned fresh
  reviewer (trivial = single file AND no new public surface AND <~40 lines AND
  no risk flag).
- Grounded verdicts (cross-cutting): reviewer dispatches carry the evidence
  slice they check against and must cite it; unverifiable claims escalate to a
  human. Reviewer prompts are report-everything; severity filtering happens in
  the reconcile/verifier pass (Opus 5 recall behavior).

## ADR-7: Harness scope is full three-harness parity  [accepted]

- Decision: codex [agents] block + turn-guard spike, OMP verifier twin +
  guard port + fan-out cap are in scope (PR4), user-locked over the leaner
  claude-first option. The ap OMP renderer stays out (accepted debt, noted
  follow-up F1); hand-authored twins carry the drift risk meanwhile.

## ADR-8: Model tiers follow phase  [accepted]

- Decision: explorer sonnet@low (judgment-shaped digests; KG playbook Table IV
  doctrine keeps haiku for schema-constrained work only); verifier new at
  haiku/luna/tiny; coder sonnet@medium with an ESCALATE contract; reviewer
  pinned opus with the router's effort dial; planner/integrator stay the
  orchestrator (opus/xhigh at mold). Orchestrator tier shifts are user
  prompts (harness-detected phrasing), never silent.

## ADR-9: Follow-up dispositions  [accepted]

- F1 ap OMP renderer: note (spec non-goal line; promote when the twins bite).
- F2 provenance-carrying shared store: published as easy-cheese#313 with the
  KG playbook attached; concrete reopen trigger recorded (wave-2 curds losing
  wave-1 facts through prose envelopes).
- F3 routing-policy drift-differ: pulled into scope (PR2.5, /harness-doctor
  check).

_Source: mold session 2026-07-24 (culture round 3 + mold round) · Updated: 2026-07-24_
