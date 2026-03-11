---
name: warn-boyscout-triage
enabled: true
event: stop
pattern: .*
action: warn
---

**🏕️ Boy Scout Rule: Leave the campground cleaner than you found it.**

Before stopping, check: did you encounter ANY failures, errors, or broken tests during this session — including ones you dismissed as "pre-existing" or "not related to our changes"?

If yes, you MUST triage them before stopping. Do NOT dismiss failures as pre-existing without evidence. "Those errors were already there" is not an ownership behavior — it's a dodge.

**Triage protocol:**

1. **Spawn a triage sub-agent** to investigate each failure:
   - Use the `/lookup` skill to efficiently trace the failure to its root cause
   - Determine: is this failure related to your changes, or genuinely pre-existing?
   - If using tests, run them on the base branch (via `git stash` or worktree) to confirm pre-existing status

2. **For failures caused by your changes:** Fix them now. Do not stop with broken code.

3. **For genuinely pre-existing failures (confirmed by evidence):**
   - Do NOT ignore them. The Boy Scout Rule applies.
   - Spawn a background agent in an isolated worktree (`isolation: "worktree"`) to:
     a. Create a fix on a clean branch from main
     b. Open a PR with the fix
     c. Title format: `fix: <description of pre-existing issue>`
   - Report back: "Found pre-existing issue X, opened PR #N to fix it"

4. **Evidence required to classify as pre-existing:**
   - Show the failure also occurs on the base branch (run the failing test/build there)
   - OR show via `git log`/`git blame` that the broken code predates your branch
   - "It looks unrelated" is NOT evidence

**What counts as a failure:**
- Test failures (unit, integration, e2e)
- Build/compile errors
- Lint or type-check errors
- Runtime errors encountered during manual testing
- CI failures after push

**The standard:** When you leave, the codebase should be at least as healthy as when you arrived. If you broke something, fix it. If you found something broken, fix it too — or open a PR so someone will.
