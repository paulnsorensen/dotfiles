# Decision Frameworks for Judgment-Heavy Skills

Most skills fail not because they lack instructions, but because they encode
rigid rules for tasks that require judgment. "Always do X" breaks the first
time an edge case appears.

The fix: encode *reasoning scaffolds* that help Claude think through decisions
rather than memorize answers.

## Pattern 1: Structured Reasoning Scaffold (Classify → Ground → Context → Reassess)

General-purpose framework for any task where "it depends" is the honest answer.

**1. Classify** — What kind of input is this? Categorize before acting.
**2. Ground** — Check the facts. Read the code/data/evidence, not just the request.
**3. Context** — What's the broader situation? Norms, authority, project phase, risk.
**4. Reassess** — Given all the above, does your initial instinct still hold?

### Example: PR Review Triage

```
1. Classify: Bug, security, architecture, convention, preference, or nitpick?
2. Ground: Read the diff. Does the reviewer's concern hold up against the code?
3. Context: Who's reviewing? Blocking or advisory? Team norms? Time pressure?
4. Reassess: Your gut said "push back" — still make sense with full picture?
```

### Example: Dependency Evaluation

```
1. Classify: Core functionality, convenience, feature-specific, or transient?
2. Ground: How much code to avoid it? Maintenance status? Transitive deps? Vulns?
3. Context: Team familiarity? Existing deps serving similar purpose? Regulated?
4. Reassess: "Convenience" dep with 50 transitive deps might not be worth it.
```

## Pattern 2: Degrees of Freedom

Match constraint level to risk. Not all instructions should have the same rigidity.

**High freedom** (guidelines) — multiple valid approaches:
```
When writing API error responses, consider consistency with existing format,
sufficient detail for corrective action, and not leaking internals.
```

**Medium freedom** (templates) — preferred pattern exists:
```
Database queries should use the repository pattern:
1. Define in src/repositories/[entity].ts
2. Use parameterized queries (never string interpolation)
3. Return typed results
```

**Low freedom** (exact steps) — operations are fragile:
```
Production database migrations MUST follow this exact sequence:
1. Create migration file
2. Review generated SQL
3. Test on staging
4. Verify staging data integrity
5. Only after verification: deploy to prod

Step 4 exists because we lost data in 2024-03 by skipping verification.
```

The metaphor: narrow bridge with cliffs = exact steps. Open field = general direction.

## Pattern 3: Example-Driven Specification

Examples are the highest-signal content per token. One good example communicates
more than a page of abstract rules.

```
## Commit Message Format

Example 1:
Input: Added user authentication with JWT tokens
Output: feat(auth): implement JWT-based authentication

Example 2:
Input: Fixed bug where users couldn't reset password on mobile
Output: fix(auth): resolve mobile password reset flow

Example 3 (edge case):
Input: Updated dependencies and fixed linting errors
Output: chore(deps): update dependencies and fix lint warnings

Note: When a change spans multiple types, use the most impactful one.
```

Three examples cover more ground than a paragraph of rules.

## Pattern 4: Gotchas Section

Every skill should include a Gotchas section capturing known failure modes.
Build over time: every time Claude fails while using the skill, add it.

```
## Gotchas

- Claude tends to run `npm install` without checking if the package is already
  in package.json. Always check existing dependencies first.

- When generating TypeScript interfaces, Claude makes all fields required.
  Check the API response to determine which are actually optional.

- Claude defaults to SELECT * instead of selecting specific columns.
  Always select only the columns needed.
```

These are worth more per token than any other content because they directly
prevent the most common failures.

## Combining Patterns

A well-structured judgment-heavy skill uses:
1. Structured reasoning scaffold for the overall decision process
2. Degrees of freedom matched to risk for each sub-task
3. "Why" explanations for every constraint
4. Examples for the trickiest parts
5. Gotchas for known failure modes

The result: Claude doesn't just follow instructions — it reasons about the
domain. This produces better results on novel inputs the author never anticipated.
