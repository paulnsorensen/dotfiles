---
name: respond
description: >
  Respond to PR review comments with confidence-rated triage. Handles both
  inline review threads (anchored to diff lines) AND PR-level review body
  comments (summaries submitted with reviews, like Age tables or Copilot
  overviews). Use when the user says "respond to PR comments", "handle review
  feedback", "address PR reviews", or invokes /respond with a PR number. Also
  trigger when the user mentions a specific PR and wants to deal with reviewer
  suggestions — whether from Copilot, human reviewers, or bots. Reads all
  unresolved review threads and review bodies, scores each suggestion 0-100,
  and presents a triage table. High-confidence fixes (>= 75) execute
  immediately while the user reviews uncertain items.
---

# Respond: PR Review Triage

Read review comments on a PR, rate each one, and act based on confidence —
fix the obvious ones immediately, push back on the bad ones, and ask about
the uncertain ones while the fixes are already underway.

## Phase 1: Fetch Review Threads and Review Bodies

Determine owner/repo from the current git remote. Then fetch both inline review
threads AND PR-level review bodies:

**Inline review threads** (comments anchored to specific diff lines):
```
pull_request_read(method: "get_review_comments", owner, repo, pullNumber)
```

**PR-level review bodies** (summary comments submitted with a review):
```
gh api repos/{owner}/{repo}/pulls/{pullNumber}/reviews
```

Also fetch PR metadata for context:
```
pull_request_read(method: "get", owner, repo, pullNumber)
pull_request_read(method: "get_diff", owner, repo, pullNumber)
```

### Inline threads
Filter to **unresolved threads only** (`is_resolved: false`). Skip outdated
threads (`is_outdated: true`) unless the user asks to include them.

Group comments by thread — a thread is a logical unit (one review suggestion
and its replies). The first comment in a thread is the review suggestion;
subsequent comments are the conversation.

### Review bodies
Filter reviews to those with a **non-empty `body`** field. Reviews with empty
bodies are just containers for inline comments and can be ignored here.

A review body is a PR-level summary — things like Age Review tables, Copilot
overviews, or reviewer summaries submitted with `CHANGES_REQUESTED` or
`COMMENTED` state. These often contain multiple suggestions in a single body.

**Deduplication**: A review that has both a body AND inline comments will appear
in both fetches. Score the inline comments as threads (they have file context).
Only score the review body for suggestions NOT already covered by its inline
comments — check `pull_request_review_id` to link inline comments back to their
parent review.

## Phase 2: Assess Each Thread

For each unresolved thread or review body item, read:
1. The reviewer's suggestion (first comment in thread, or extracted from review body)
2. Any follow-up discussion
3. The relevant code from the diff (for inline threads) or the full PR diff (for review body items)

Then assign a **confidence score (0-100)** representing how confident you are
that the reviewer's suggestion is correct and valuable. This is your assessment
of the suggestion's merit, not the reviewer's confidence.

**Review body parsing**: A single review body may contain multiple distinct
suggestions (bullet points, numbered lists, table rows). Parse these into
individual items when possible — each gets its own score and triage row. If the
body is a single cohesive comment (e.g., "LGTM" or a general observation),
treat it as one item.

**Review state as signal**: `CHANGES_REQUESTED` carries more weight than
`COMMENTED` — the reviewer explicitly flagged something as blocking. Factor this
into scoring (it raises confidence that the suggestion matters, though it
doesn't automatically make the suggestion *correct*).

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

| # | Score | Reviewer | Location | Summary | Action |
|---|-------|----------|----------|---------|--------|
| 1 | 92 | copilot | auth.ts:42 | Missing null check on token | FIX |
| 2 | 85 | alice | api.ts:78 | Error not propagated to caller | FIX |
| 3 | 78 | alice | (review body) | Missing error handling in 3 endpoints | FIX |
| 4 | 60 | copilot | utils.ts:15 | Extract to shared helper | ASK |
| 5 | 35 | bob | index.ts:3 | Add backward compat shim | PUSH BACK |
| 6 | 20 | copilot | (review body) | General "consider adding tests" | SKIP |

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

### 3. Missing error handling in 3 endpoints (78) — FIX [review body]
> alice (CHANGES_REQUESTED): "The new endpoints in handler.rs don't propagate
> database errors — they silently return empty results."
Plan: Add error propagation in the 3 endpoints she identified.

### 4. Extract to shared helper (60) — ASK
> copilot: `formatDate()` is duplicated in 3 files
This is a real duplication but extracting now adds a shared module.
Worth it, or leave for a dedicated cleanup pass?

### 5. Add backward compat shim (35) — PUSH BACK
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
3. Reply acknowledging the fix:
   - **Inline threads**: reply to the thread:
     ```
     add_reply_to_pull_request_comment(owner, repo, pullNumber, commentId, body)
     ```
   - **Review body items**: post a PR conversation comment referencing the review:
     ```
     gh api repos/{owner}/{repo}/issues/{pullNumber}/comments \
       -f body="Re: @reviewer's review — Fixed: <brief description>."
     ```
   ```
   Fixed — <brief description of what changed>.
   ```

### For PUSH BACK items (< 50):
1. Post the reply:
   - **Inline threads**:
     ```
     add_reply_to_pull_request_comment(owner, repo, pullNumber, commentId, body)
     ```
   - **Review body items**:
     ```
     gh api repos/{owner}/{repo}/issues/{pullNumber}/comments \
       -f body="Re: @reviewer's review — <pushback explanation>."
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
