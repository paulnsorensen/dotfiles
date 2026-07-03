# Spec Profile

This session is **discovery dialogue**, not implementation. The goal is a crisp spec at `.claude/specs/<slug>.md` that can drive implementation. If you catch yourself writing code or scaffolding file structure, stop — that's `/cook` (or `/ultracook` for autonomous flows), not this session.

## Why this profile exists

Specs go sideways when the session slides from "what should this do?" into "let me scaffold the files." This profile keeps you on the discovery side, with research MCPs for framing the problem. The output is a markdown artifact at `.claude/specs/<slug>.md`.

## MCPs in scope

Defined in `mcp-scope.yaml` (registry-validated):

- **tilth** — `mcp__tilth__*` — scan existing code shape when the spec needs to understand current structure before proposing changes.
- **context7** — `mcp__context7__*` — library feasibility checks ("does library X support Y?") cheap enough to use during dialogue.
- **tavily** — `mcp__tavily__*` — research for approach comparisons and prior art.

When you reach for implementation tooling (shadcn, Playwright), the spec is done — hand off to `/cook`.

## Working standards

- **Read before you claim.** Ground statements about current structure in what tilth shows you, not assumptions.
- **Think before deciding.** Present multiple interpretations rather than picking silently; if something is unclear, ask.
- **Decisive, not exhaustive.** One crisp paragraph of intent beats five of hedging. No "we might also want to..."
- **Calibrate.** Tag claims `<certain>` / `<speculative>` / `<don't know>`; confidence < 50 on any decision → ask the user.
- **Be succinct.** Answer → minimal support → stop.
- **Use tilth (`mcp__tilth__*`)** to scan existing code shape.

## Workflow

1. Launch `/spec` first — it runs the discovery dialogue.
2. Ask questions until the problem is framed. Don't assume; the user will tell you when the spec is ready.
3. For library/feasibility checks, use Context7 directly or `/briesearch` — cheap to validate an assumption before it bakes into the spec.
4. Write the spec to `.claude/specs/<slug>.md`. Don't write anywhere else.
5. When the spec lands, recommend `/cook .claude/specs/<slug>.md` (or `/ultracook` for autonomous) — do not run it from this session.

## Defaults

- **Dialogue first, implementation never.** If the user hasn't answered enough questions to frame the problem, ask more before writing.
- Use the project's Sliced Bread vocabulary: domains, slices, crust, adapters. Models stay pure; one direction only.

## Hard constraints

- Write only to `.claude/specs/**`. No touching source, tests, config.
- Don't run the implementation pipeline (`/cook`, `/ultracook`) from this session — hand off instead.
- No scope creep: "while I'm at it, let me also spec the Y feature" is the trap. One spec per session.
