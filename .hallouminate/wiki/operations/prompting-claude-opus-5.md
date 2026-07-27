# Prompting Claude Opus 5 — behavior deltas that change our routing

Official guidance ("Prompting Claude Opus 5", platform.claude.com, released
2026-07-24) distilled to what changes decisions in this repo: model-tier pins,
review fan-out sizing, verification scaffolding, and delegation restraint. The
model runs well on existing Opus 4.8 prompts out of the box; the deltas below
are where tuning pays. Raw guide: the URL in the footer (a local copy sits in
`reference/`, gitignored — the wiki page is the durable home).

## Capability deltas that matter here

- **Review accuracy holds at low effort.** High precision AND recall per review
  pass, holding at lower effort settings — a fast cheap pass at review time
  plus a thorough later pass is a supported pattern. Effort becomes a second
  dial on review cost, beside reviewer count.
- **Severity-conservative review prompts suppress recall.** "Only report
  high-severity issues" / "be conservative" is followed literally — the model
  reports less. Ask reviewers to report everything and filter in a separate
  (cheap) pass instead. Affects every /age-style reviewer prompt.
- **Delegates to subagents more readily than prior models.** Delegation
  guidance must be explicit (which scenarios warrant it) or deterministically
  capped — see [[architecture/subagent-turn-budgets]] for the caps. Don't
  delegate handful-of-tool-call work; don't spawn subagents to verify your own
  work; one subagent when one suffices. Multi-agent coordination itself is
  strong (writer–verifier patterns work, few overwrite conflicts).
- **Verifies and self-corrects unprompted.** Explicit verification
  instructions ("include a final verification step", "use a subagent to
  verify", "double-check your answer") compound with native behavior into
  over-verification — remove them from prompts and harness scaffolding aimed
  at Opus 5. Scaffolding that checks a *cheaper writer* (an opus reviewer over
  a sonnet coder) is a different case and still earns its keep.
- **Scope expansion.** It may add unrequested steps or reinterpret the task;
  narrow tasks want an explicit scope constraint ("deliver what was asked, at
  the scope intended; say so in a sentence and continue as asked rather than
  quietly narrowing, widening, or transforming").
- **Agentic coding profile.** Strongest on hard multi-file work; completes
  tasks rather than leaving stubs; performs best given the complete spec up
  front and left to run — reinforces spec-freeze-then-execute pipelines.
- **1M-token context is default and max**, with instruction following, tool
  calling, and reasoning consistent throughout — context ceilings tuned for
  200K-era windows are cost backstops, not capability cliffs.

## Effort and thinking mechanics

- `low`/`medium` effort produce strong quality at a fraction of tokens and
  latency, above the same settings on prior Opus models; `xhigh` remains the
  recommended starting point for coding and agentic work. Re-run effort sweeps
  when migrating — carried-over defaults mis-spend.
- Effort controls **thinking volume, not visible response length** — prompt
  for conciseness explicitly; lowering effort won't shorten replies.
- Thinking is **on by default** and can be disabled only at effort `high` or
  below. With thinking disabled, two occasional artifacts: tool calls written
  as user-facing text (the call never runs, and the leaked text poisons later
  turns), and internal XML tags in output. Mitigation: keep thinking on and
  control cost with effort. If thinking must stay off: grant "a brief sentence
  before using a tool", and use the general "do not include internal or system
  XML tags" phrasing — naming thinking tags specifically increases leakage, as
  do "don't think / don't reason" rules.

## Prompt-side length control

- Conversational verbosity: a short conciseness instruction, paired with a
  short reminder near the end of a long system prompt.
- Narration: describe the cadence wanted (one sentence before the first tool
  call; brief updates only on findings or direction changes; finish leading
  with the outcome). Positive examples beat prohibitions.
- Files written to disk run longer than prior models' — calibrate separately
  ("cover the substance; no filler sections, redundant summaries, or
  boilerplate").

## Local implications (2026-07-24)

For the routing overhaul (spec `.cheese/specs/subagent-routing-overhaul.md`):
review fan-out gains an **effort dial** beside the count dial; reviewer prompts
must drop severity-conservative phrasing in favor of report-everything + cheap
filter pass; preamble/skill delegation language needs the explicit restraint
block; verification scaffolding should distinguish "check a cheaper writer"
(keep) from "re-verify your own work" (drop for Opus 5 orchestrators).

*Source: platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-opus-5 (fetched 2026-07-24, source-hash 9a680a14e9bdf39a) · Updated: 2026-07-24*
