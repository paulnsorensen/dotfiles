# Anti-Patterns: The 20 Most Common Skill Mistakes

Scan every skill you improve against this list.

## Activation

1. **Summary description** — "A tool for X" never fires. Rewrite as trigger spec.
2. **First-person description** — "I help with..." breaks POV in system prompt.
3. **Missing negative triggers** — No "Do NOT use for..." causes false activation.
4. **Narrow keywords** — Only exact phrases, no synonyms or casual phrasings.

## Context

1. **Teaching Claude what it knows** — Python syntax, REST APIs, common patterns.
   Only add knowledge Claude doesn't have.
2. **CLAUDE.md bloat** — 200+ lines with specialized workflows. Move to skills.
   Keep CLAUDE.md under 80 lines with only global rules.
3. **Deep reference chains** — SKILL.md → ref-a.md → ref-b.md. Max one level deep.
4. **Monolithic SKILL.md** — 800+ lines. Split into SKILL.md (<500) + references.
5. **Inline scripts** — Step-by-step instructions that are really a script.
   Extract to `scripts/` — executes without loading into context.

## Instructions

1. **Negation-heavy rules** — "Do NOT use X" fails ~50%. Use "Use Y exclusively."
2. **Rules without reasons** — "Always use named exports" gives no basis for
    edge cases. Add why: enables tree-shaking, safer refactoring.
3. **"Always/never" for judgment tasks** — Works for mechanical tasks (always
    run tests). Fails for judgment tasks where context determines the answer.
    Use structured reasoning scaffold instead. See `decision-frameworks.md`.
4. **No examples** — Abstract rules without concrete input → output examples.
    Two examples communicate more than a page of rules.
5. **Missing Gotchas section** — No record of known failure modes. Add one and
    update it every time Claude fails while using the skill.
6. **Uniform constraint level** — Every instruction has the same force. Match
    constraint level to risk: high freedom for style, low for production deploys.

## Enforcement

1. **Critical rules as instructions only** — CLAUDE.md says "always run tests."
    Claude doesn't. Implement as a hook — instructions are requests, hooks are laws.
2. **No primacy/recency anchoring** — Most-violated rules buried in the middle.
    Place the 3 most critical rules at TOP and BOTTOM of CLAUDE.md.
3. **Missing companion hooks** — Skill works in testing but fails in real use.
    Add the trinity: Skill (knowledge) + Hook (enforcement) + Command (invocation).

## Architecture

1. **`context: fork` on guideline-only skills** — Guidelines have no task.
    Subagent gets guidelines but no actionable prompt, returns nothing useful.
2. **Opus 4.6 subagent overuse** — Simple tasks spawn unnecessary subagents.
    Add explicit anti-fork guidance: "Do NOT fork for single-file operations."

## Diagnostic Checklist

- [ ] Description is a trigger spec, not a summary
- [ ] Description in third person with explicit "Use when" + keywords
- [ ] Description has "Do NOT use for" anti-triggers
- [ ] SKILL.md under 500 lines
- [ ] No content Claude already knows
- [ ] References max one level deep
- [ ] No inline scripts that should be external files
- [ ] Instructions framed positively
- [ ] Every rule has a "why"
- [ ] Judgment tasks use structured reasoning scaffold, not rigid rules
- [ ] At least 2-3 examples for tricky patterns
- [ ] Gotchas section exists
- [ ] Constraint level matches risk level
- [ ] Critical rules enforced by hooks
- [ ] `context: fork` only on task-oriented skills
