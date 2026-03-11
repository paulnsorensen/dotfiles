---
name: respond
description: >
  Respond to PR review comments with confidence-rated triage. Use when the user
  says "respond to PR comments", "handle review feedback", "address PR reviews",
  or invokes /respond with a PR number. Also trigger when the user mentions
  a specific PR and wants to deal with reviewer suggestions — whether from
  Copilot, human reviewers, or bots. Reads all unresolved review threads,
  scores each suggestion 0-100, and presents a triage table. High-confidence
  fixes (>= 75) execute immediately while the user reviews uncertain items.
---

# Respond: PR Review Triage

Read review comments on a PR, rate each one, and act based on confidence —
fix the obvious ones immediately, push back on the bad ones, and ask about
the uncertain ones while the fixes are already underway.

## Phase 1: Fetch Review Threads

Determine owner/repo from the current git remote. Then fetch unresolved review
threads using the GitHub MCP plugin:

```
pull_request_read(method: "get_review_comments", owner, repo, pullNumber)
```

Also fetch PR metadata for context:
```
pull_request_read(method: "get", owner, repo, pullNumber)
pull_request_read(method: "get_diff", owner, repo, pullNumber)
```

Filter to **unresolved threads only** (`is_resolved: false`). Skip outdated
threads (`is_outdated: true`) unless the user asks to include them.

Group comments by thread — a thread is a logical unit (one review suggestion
and its replies). The first comment in a thread is the review suggestion;
subsequent comments are the conversation.

## Phase 2: Assess Each Thread

For each unresolved thread, read:
1. The reviewer's suggestion (first comment in thread)
2. Any follow-up discussion
3. The relevant code from the diff

Then assign a **confidence score (0-100)** representing how confident you are
that the reviewer's suggestion is correct and valuable. This is your assessment
of the suggestion's merit, not the reviewer's confidence.

**Scoring guidance:**

| Score | Meaning | Signals |
|-------|---------|---------|
| 90-100 | Clearly correct | Catches a real bug, missing validation, or factual error |
| 75-89 | Good suggestion | Improves clarity, matches codebase conventions, or fixes a real gap |
| 50-74 | Debatable | Style preference, trade-off with no clear winner, or context-dependent |
| 25-49 | Likely wrong | Misunderstands intent, suggests unnecessary complexity, or conflicts with project conventions |
| 0-24 | Clearly wrong | Factually incorrect, contradicts documented patterns, or would introduce a bug |

**What raises confidence:**
- Suggestion catches a real bug or security issue
- Points out a missing edge case with a concrete example
- Aligns with patterns documented in CLAUDE.md or the codebase
- Multiple reviewers agree

**What lowers confidence:**
- Reviewer is a bot making a generic observation
- Suggestion adds complexity without clear benefit
- Conflicts with the project's stated conventions (YAGNI, complexity budget, etc.)
- "You should also..." additions that weren't in the original scope
- Backward-compatibility concerns in early-development projects (per Early Development Stance)

## Phase 3: Triage Table + Immediate Execution

Present the full triage table so the user sees everything at once:

```
## PR #N Review Triage

| # | Score | Reviewer | File:Line | Summary | Action |
|---|-------|----------|-----------|---------|--------|
| 1 | 92 | copilot | auth.ts:42 | Missing null check on token | FIX |
| 2 | 85 | alice | api.ts:78 | Error not propagated to caller | FIX |
| 3 | 60 | copilot | utils.ts:15 | Extract to shared helper | ASK |
| 4 | 35 | bob | index.ts:3 | Add backward compat shim | PUSH BACK |

### Legend
- **FIX** (>= 75): Agree and implement — proceeding now
- **ASK** (50-74): Needs your call — what do you want to do?
- **PUSH BACK** (< 50): Draft reply below — edit or approve
```

For each row, include a one-line expansion:

```
### 1. Missing null check on token (92) — FIX
> copilot: `token` could be undefined when auth header is malformed
Plan: Add null guard before decode, return 401

### 3. Extract to shared helper (60) — ASK
> copilot: `formatDate()` is duplicated in 3 files
This is a real duplication but extracting now adds a shared module.
Worth it, or leave for a dedicated cleanup pass?

### 4. Add backward compat shim (35) — PUSH BACK
> bob: Users on v1 will break without a migration path
Draft reply: "This project is pre-release with zero users and no production
data — backward compatibility isn't a concern yet per our Early Development
Stance. We'll add migration support when there's something to migrate from."
```

**Then immediately — in the same turn:**

1. Start fixing all FIX items (>= 75) while the user reviews ASK and PUSH BACK items
2. Post PUSH BACK replies for items scored < 50 (the user can override before you get to them, but don't wait)
3. Ask the user about ASK items (50-74):
   - "Should I fix this, push back, or skip?"
   - Include enough context for a quick decision

The triage table is informational, not a gate for high-confidence items. The user
sees what's happening and can interrupt ("stop, don't fix #2") but the default is
to move fast on the obvious stuff.

## Phase 4: Execute

### For FIX items (>= 75):
1. Read the relevant source file
2. Implement the fix
3. Reply to the thread acknowledging the fix:
   ```
   Fixed — <brief description of what changed>.
   ```

### For PUSH BACK items (< 50):
1. Post the draft reply to the thread using:
   ```
   add_reply_to_pull_request_comment(owner, repo, pullNumber, commentId, body)
   ```
2. Keep the tone professional and specific — explain *why*, not just *no*

### For ASK items (50-74) after user decides:
- Execute as FIX or PUSH BACK based on the user's decision
- If the user doesn't respond to a specific ASK, leave it unresolved

### After all actions:
If any code was changed, commit the fixes (using the `commit` skill) and
push to the PR branch. Present a summary: files modified, threads replied to,
threads still pending user decision.

## Rules

- **Show the triage table before executing** — but don't wait for approval on >= 75 items
- **One reply per thread** — don't fragment responses across multiple comments
- **Match the reviewer's tone** — professional for humans, concise for bots
- **Cite specifics in pushback** — reference CLAUDE.md conventions, complexity budget, or early-dev stance when relevant
- **Don't argue style** — if the suggestion is purely stylistic and score is < 50, just skip it rather than posting a pushback (note it as SKIP in the table)
- **Batch commits** — group all fixes into one commit, not one per thread
- **User can override anything** — if they say "don't fix #2" before you get to it, stop. If they say "actually fix #4", do it. The confidence score is a default, not a mandate.
