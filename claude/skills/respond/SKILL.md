---
name: respond
model: sonnet
description: >
  Respond to PR review comments with confidence-rated triage. Also checks and
  fixes build failures and merge conflicts before processing comments. Handles
  both inline review threads (anchored to diff lines) AND PR-level review body
  comments (summaries submitted with reviews, like Age tables or Copilot
  overviews). Use when the user says "respond to PR comments", "handle review
  feedback", "address PR reviews", "fix the build", "fix CI", "fix merge
  conflicts", or invokes /respond with a PR number. Also trigger when the user
  mentions a specific PR and wants to deal with reviewer suggestions — whether
  from Copilot, human reviewers, or bots. Checks CI status and mergeability
  first, then reads all unresolved review threads and review bodies, scores
  each suggestion 0-100, and presents a triage table. High-confidence fixes
  (>= 70) execute immediately while the user reviews uncertain items. Do NOT
  use to generate a new review — use /copilot-review for that.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(gh:*), Bash(git:*), mcp__plugin_github_github__pull_request_read, mcp__plugin_github_github__add_reply_to_pull_request_comment, mcp__plugin_github_github__add_issue_comment
---

# Respond: PR Review Triage

Read review comments on a PR, rate each one, and act based on confidence —
fix the obvious ones immediately, push back on the bad ones, and ask about
the uncertain ones while the fixes are already underway.

## Phase 0: PR Health Check

Before triaging comments, check the PR's build and merge status:

```
pull_request_read(method: "get_check_runs", owner, repo, pullNumber)
pull_request_read(method: "get", owner, repo, pullNumber)  # check mergeable_state
```

**Build failures**: If any check run has `conclusion: "failure"`, fetch the
failed job logs (`gh run view <run_id> --log-failed`) and fix the root cause
before processing review comments. Build fixes go first — review comments may
be moot if the build is broken.

**Merge conflicts**: If the PR's `mergeable` field is `false` or `mergeable_state`
is `"dirty"`, rebase onto `origin/main` and force-push (with lease) before
processing comments. Stale conflicts block everything downstream.

Include build/merge status at the top of the triage table:

```
## PR #N Status
- **Build**: passing | failing (N jobs)
- **Merge**: clean | conflicts (rebase needed)
```

If both are clean, proceed to Phase 1. If fixes were needed, note what was done.

## Phase 1: Fetch Review Threads and Review Bodies

Determine owner/repo from the current git remote. Then fetch both inline review
threads AND PR-level review bodies:

**Inline review threads** (comments anchored to specific diff lines):
```
pull_request_read(method: "get_review_comments", owner, repo, pullNumber)
```

**PR-level review bodies** (summary comments submitted with a review):
```
pull_request_read(method: "get_reviews", owner, repo, pullNumber)
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

### Step 3: Score Each Suggestion (4-Step Calibration)

**Step 1 — Classify suggestion type:**

| Type | Description | Base | Cap |
|------|-------------|------|-----|
| BUG | Correctness issue, logic error, crash | 50 | 100 |
| SECURITY | Vulnerability, data exposure, auth bypass | 55 | 100 |
| CONVENTION | Style, naming, project-standard deviation | 25 | 65 |
| STYLE | Formatting, subjective preference | 15 | 50 |
| SCOPE_CREEP | Unrelated improvement, "while you're here" | 20 | 55 |
| VALID_CONCERN | Architectural, performance, maintainability | 40 | 90 |

**Step 2 — Evidence grounding:**

| Evidence | Modifier |
|----------|----------|
| Reviewer cites specific code with accurate analysis | +20 |
| Suggestion references project convention or CLAUDE.md rule | +15 |
| Generic observation without specific code reference | -10 |
| Reviewer misreads the code or cites wrong line | hard cap 0 |

**Step 3 — Context modifiers:**

| Signal | Modifier |
|--------|----------|
| CHANGES_REQUESTED review state | +10 |
| Reviewer is a maintainer/codeowner | +10 |
| Bot reviewer (Copilot, CodeRabbit, etc.) | -10 |
| Suggestion duplicates another thread | -15 |
| Pre-existing issue not introduced by this PR | -15 |

**Step 4 — Re-assess borderline (55-69):**
For items near the FIX threshold: re-read the reviewer's comment and the relevant code independently. Score a second time without looking at your first score. If the two scores diverge >15 points, the suggestion is ambiguous — keep as ASK. If both land >= 70, upgrade to FIX.

## Phase 3: Triage Table + Immediate Execution

Present the full triage table so the user sees everything at once:

```
## PR #N Review Triage

| # | Score | Type | Reviewer | Location | Summary | Action |
|---|-------|------|----------|----------|---------|--------|
| 1 | 92 | BUG | copilot | auth.ts:42 | Missing null check on token | FIX |
| 2 | 85 | BUG | alice | api.ts:78 | Error not propagated to caller | FIX |
| 3 | 78 | VALID_CONCERN | alice | (review body) | Missing error handling in 3 endpoints | FIX |
| 4 | 60 | STYLE | copilot | utils.ts:15 | Extract to shared helper | ASK |
| 5 | 35 | SCOPE_CREEP | bob | index.ts:3 | Add backward compat shim | PUSH BACK |
| 6 | 20 | STYLE | copilot | (review body) | General "consider adding tests" | SKIP |

### Legend
- **FIX** (>= 70): Agree and implement — proceeding now
- **ASK** (50-69): Needs your call — what do you want to do?
- **PUSH BACK** (< 50): Draft reply below — edit or approve
```

For each row, include a one-line expansion (representative examples below):

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

1. Start fixing all FIX items (>= 70) while the user reviews ASK and PUSH BACK items
2. Post PUSH BACK replies for items scored < 50 (the user can override before you get to them, but don't wait)
3. Ask the user about ASK items (50-69):
   - "Should I fix this, push back, or skip?"
   - Include enough context for a quick decision

The triage table is informational, not a gate for high-confidence items. The user
sees what's happening and can interrupt ("stop, don't fix #2") but the default is
to move fast on the obvious stuff.

## Phase 4: Execute

### For FIX items (>= 70):
1. Read the relevant source file
2. Implement the fix
3. Reply acknowledging the fix:
   - **Inline threads**: reply to the thread:
     ```
     add_reply_to_pull_request_comment(owner, repo, pullNumber, commentId, body)
     ```
   - **Review body items**: post a PR conversation comment referencing the review:
     ```
     add_issue_comment(owner, repo, number: pullNumber, body: "Re: @reviewer's review — Fixed: <brief description>.")
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
     add_issue_comment(owner, repo, number: pullNumber, body: "Re: @reviewer's review — <pushback explanation>.")
     ```
2. Keep the tone professional and specific — explain *why*, not just *no*

### For ASK items (50-69) after user decides:
- Execute as FIX or PUSH BACK based on the user's decision
- If the user doesn't respond to a specific ASK, leave it unresolved

### After all actions:
If any code was changed, commit the fixes (using the `commit` skill) and
push to the PR branch. Present a summary: files modified, threads replied to,
threads still pending user decision.

## Rules

- **Show the triage table before executing** — but don't wait for approval on >= 70 items
- **One reply per thread** — don't fragment responses across multiple comments
- **Match the reviewer's tone** — professional for humans, concise for bots
- **Cite specifics in pushback** — reference CLAUDE.md conventions, complexity budget, or early-dev stance when relevant
- **Don't argue style** — if the suggestion is purely stylistic and score is < 50, just skip it rather than posting a pushback (note it as SKIP in the table)
- **Never defer to a follow-up** — don't reply "will address in a follow-up PR" or "good idea, will do in a separate PR". If it scores >= 70, fix it now. If it scores < 50, push back. The only valid deferral is an ASK item (50-69) that the user explicitly decides to skip.
- **Batch commits** — group all fixes into one commit, not one per thread
- **User can override anything** — if they say "don't fix #2" before you get to it, stop. If they say "actually fix #4", do it. The confidence score is a default, not a mandate.

## What This Skill Never Does

- Generate a new review — use `/copilot-review` for that
- Refactor code beyond the specific fix a reviewer requested
- Add tests unless a reviewer explicitly asked for them
- Open new issues or PRs beyond the one being triaged
- Change files not referenced in review comments
- Resolve threads it didn't reply to — let GitHub auto-resolve

## Gotchas

- GitHub MCP rate limits hit on PRs with 50+ comments — batch reads where possible
- Review body parsing can split cohesive comments into fragments — check for related threads
- `is_resolved` field is not always reliable across GitHub Apps — verify thread state manually
- Bot reviewers with CHANGES_REQUESTED state inflate perceived urgency — apply -10 modifier
- Deduplication between inline comments and review body summaries is tricky — check for overlap before acting
