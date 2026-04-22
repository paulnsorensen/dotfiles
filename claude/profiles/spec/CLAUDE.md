# Spec Profile

This session is **discovery dialogue**, not implementation. The goal is
to produce a crisp spec at `.claude/specs/<slug>.md` that `/fromagerie`
can decompose into atoms. If you catch yourself writing code or
scaffolding file structure, stop — that's `/fromage` or `/fromagerie`,
not this session.

## Why this profile exists

Specs go sideways when the session slides from "what should this do?" into
"let me scaffold the files." This profile keeps you on the discovery side:
no implementation MCPs, broad research MCPs instead. The output is a
markdown artifact at `.claude/specs/<slug>.md`, not code.

## MCPs in scope

Defined in `mcp-scope.yaml` (registry-validated):

- **tilth** — `mcp__tilth__*` — scan existing code shape when the spec needs to understand current structure before proposing changes.
- **context7** — `mcp__context7__*` — library feasibility checks ("does library X support Y?") cheap enough to use during dialogue.
- **tavily** — `mcp__tavily__*` — AI-powered research for approach comparisons and prior art.
- **serper** — `mcp__serper__*` — factual lookups and SERP features when a quick Google answer beats a 2K-token Tavily response.

Implementation MCPs (code-review-graph, shadcn, Playwright) are out of scope
— if you need them, the spec is done and it's time for `/fromagerie`.

## Workflow

1. Launch `/spec` first — it runs the discovery dialogue.
2. Ask questions until the problem is framed. Don't assume; the user
   will tell you when the spec is ready.
3. For library/feasibility checks, use Context7 (`/fetch`) or `/research`
   — cheap to validate an assumption before it bakes into the spec.
4. Write the spec to `.claude/specs/<slug>.md`. Don't write anywhere else.
5. When spec lands, recommend `/fromagerie .claude/specs/<slug>.md` — do not run it from this session.

## Defaults

- **Dialogue first, implementation never.** If the user hasn't answered
  enough questions to frame the problem, ask more before writing.
- Specs are decisive, not exhaustive. One crisp paragraph of intent
  beats five paragraphs of hedging. No "we might also want to..."
- Use the project's Sliced Bread vocabulary: domains, slices, crust,
  adapters. Models stay pure; one direction only.
- Confidence < 50 on any decision → ask the user. Never decide silently.

## Hard constraints

- Write only to `.claude/specs/**`. No touching source, tests, config.
- Don't run the implementation pipeline (`/fromage`, `/fromagerie`,
  `/cook`) from this session — hand off instead.
- No scope creep: "while I'm at it, let me also spec the Y feature"
  is the trap. One spec per session.
