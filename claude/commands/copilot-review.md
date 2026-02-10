---
allowed-tools: Bash(gh *), Bash(git *), Bash(jq *), Bash(cat *), Read, Grep, AskUserQuestion
description: Review a PR and route fixes to GitHub Copilot via inline comments.
argument-hint: "<PR number or URL>"
---

Review a pull request with a teaching focus, then post inline comments that @mention Copilot to fix issues.

**Input:** $ARGUMENTS

## Review Philosophy

This review follows four principles:
1. **What's working well** — Be specific about good patterns, not just problems
2. **Questions to consider** — Prompt the author to think, not just comply
3. **Teaching moments** — Every suggestion explains the "why", not just the "what"
4. **Every line must justify itself** — Apply the ricotta-reducer lens: flag speculative abstractions, unnecessary indirection, and code that adds weight without value

## Phase 1: Fetch PR Context

1. Determine the PR number from the argument. If it's a URL, extract the number. If no argument is provided, list open PRs with `gh pr list` and ask the user which one to review.

2. Fetch PR metadata:
   ```
   gh pr view <number> --json title,body,author,baseRefName,headRefName,url,number,additions,deletions,changedFiles
   ```

3. Fetch the diff:
   ```
   gh pr diff <number>
   ```

4. Fetch changed files with line detail:
   ```
   gh api repos/{owner}/{repo}/pulls/<number>/files --jq '.[] | {filename, status, additions, deletions, patch}'
   ```

   Get owner/repo from: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`

5. Present a brief summary to the user:
   - PR title, author, base ← head
   - Number of files changed, additions, deletions
   - List of changed files

## Phase 2: Review the Diff

### 2a. What's Working Well

Before flagging problems, identify what the PR does right. Be specific — not "looks good" but concrete patterns worth calling out:
- Clean abstractions or well-named functions
- Good error handling patterns
- Thoughtful test coverage
- Consistent style with the existing codebase
- Smart use of language features

Present these to the user first. Good patterns deserve recognition.

### 2b. Questions to Consider

Identify 1-3 higher-level questions for the PR author to think about. These aren't necessarily problems — they're prompts that encourage deeper thinking:
- "What happens if this service is unavailable?"
- "Is this the right module for this responsibility?"
- "How does this behave under concurrent access?"

These are presented to the user but **not posted as PR comments** unless the user explicitly asks.

### 2c. Issues

Analyze the diff file by file, applying two lenses:

**Lens 1 — Correctness & Safety** (priority order):

1. **Security** — Hardcoded secrets, injection vulnerabilities, unsafe deserialization, missing input validation
2. **Bugs** — Logic errors, off-by-one, null/undefined access, race conditions, incorrect error handling
3. **Silent Failures** — Swallowed errors, empty catch blocks, missing error propagation, fallback behavior that hides problems

**Lens 2 — Architecture & Weight** (the ricotta-reducer lens):

4. **DECOUPLE** — Domain/model code importing infrastructure (HTTP, DB, file I/O, framework decorators), cross-slice internal imports, wrong direction of dependency
5. **DELETE** — Dead code, unused exports, unreachable branches, speculative abstractions (ABCs with one impl, factories with one type, registries with one entry, config that's never varied)
6. **INLINE** — Passthrough layers, single-use wrappers, one-method classes that should be functions, variables assigned and immediately returned
7. **UNDOCUMENT** — Docstrings that restate the function name, AI-generated comments that add no insight, comments on obvious code
8. **Complexity** — Functions over 40 lines, files over 300 lines, deeply nested logic, too many parameters

**Severity levels:**
- `BUG` — Will cause incorrect behavior
- `RISK` — Could cause problems under certain conditions
- `SUGGESTION` — Improvement, not required

**For each finding, prepare a review item with:**
- **File** and **line number** (the line in the PR diff where the issue exists)
- **What it does** — One sentence in business terms. Never say "this function processes data." Say "this function converts a {CustomerOrder} into the {FulfillmentRequest} the warehouse API expects."
- **Issue** — What's wrong or concerning
- **Teaching moment** — The "why" behind the suggestion. Explain the principle, not just the fix. Help the author (and Copilot) understand the reasoning so the pattern doesn't repeat elsewhere.
- **Category** — One of: `SECURITY`, `BUG`, `SILENT_FAILURE`, `DECOUPLE`, `DELETE`, `INLINE`, `UNDOCUMENT`, `COMPLEXITY`
- **Severity** — `BUG`, `RISK`, or `SUGGESTION`
- **Disposition** — One of:
  - `COPILOT_FIX` — Straightforward fix that Copilot can handle (rename, add validation, fix logic, add error handling, delete dead code, inline a wrapper, remove a restating docstring)
  - `FUTURE_TASK` — Requires broader context, architectural decision, or multi-file refactor that Copilot shouldn't attempt alone

**Do NOT flag:**
- Style/formatting issues (handled by linters)
- Import ordering
- Missing docstrings on internal functions
- Patterns that are consistent with the rest of the codebase
- Nitpicks with no functional impact
- Code you don't understand — unclear purpose is worth mentioning in "Questions to Consider", not as an issue

## Phase 3: Present Findings for Approval

### 3a. Strengths

First, present what's working well in the PR. These are not posted as comments — they're context for the reviewer (the user).

### 3b. Questions

Present the higher-level questions to consider. Ask the user if any of these should be posted as a PR comment.

### 3c. Issues

Present ALL issues to the user in a table, grouped by file:

```
### path/to/file.ts

| # | Line | Sev | Category | Issue | Disposition |
|---|------|-----|----------|-------|-------------|
| 1 | 42   | BUG | BUG      | Null check missing before `.length` access | COPILOT_FIX |
| 2 | 78   | RISK | SILENT_FAILURE | Error swallowed in catch block | COPILOT_FIX |
| 3 | 95   | SUGGESTION | INLINE | Single-use wrapper adds indirection without logic | COPILOT_FIX |
| 4 | 120  | SUGGESTION | COMPLEXITY | Extract 50-line function into smaller units | FUTURE_TASK |
```

After each file's table, show the **full comment text** that would be posted for each item, including the @copilot mention for COPILOT_FIX items.

**Comment format for COPILOT_FIX items:**
```
**[SEVERITY]**: Issue description

**Why this matters:** Teaching moment — the principle behind the fix, so the pattern doesn't repeat. Keep this to 1-2 sentences.

@copilot fix this
```

**Comment format for FUTURE_TASK items:**
```
**[SEVERITY]**: Issue description

**Why this matters:** Teaching moment — the principle behind the suggestion.

_Noted for future work — not a Copilot fix._
```

Then ask the user:
- Which comments to **post** (default: all)
- Which comments to **skip**
- Any comments to **edit** before posting
- Whether any COPILOT_FIX items should be changed to FUTURE_TASK or vice versa
- Whether any **questions** from 3b should be posted as a general PR comment

## Phase 4: Post Comments

Once the user approves, submit a single PR review with all approved comments:

1. Build a JSON payload:
   ```json
   {
     "body": "Automated review — items marked for @copilot are actionable fixes.",
     "event": "COMMENT",
     "comments": [
       {
         "path": "path/to/file.ts",
         "line": 42,
         "side": "RIGHT",
         "body": "**BUG**: Null check missing...\n\n@copilot fix this"
       }
     ]
   }
   ```

2. Submit using:
   ```
   gh api repos/{owner}/{repo}/pulls/<number>/reviews --method POST --input /tmp/pr-review-payload.json
   ```

3. After posting, display a summary:
   - Total comments posted
   - Comments routed to Copilot (COPILOT_FIX count)
   - Comments noted for future work (FUTURE_TASK count)
   - Link to the PR

4. Clean up the temp file.

## Important Rules

- **Never post without user approval.** Always show exactly what will be posted and wait for confirmation.
- **Frame in business terms.** Never say "this function processes data." Say "this function converts a {CustomerOrder} into the {FulfillmentRequest} the warehouse API expects." Reference what the code does for the domain, not its technical mechanics.
- **Be specific.** Every comment must reference a concrete line and explain why it matters.
- **Respect the codebase.** If a pattern is used consistently in the repo, don't flag it.
- **Keep comments actionable.** Copilot needs clear direction. "Fix this" without context won't work — describe the expected behavior.
- **One comment per issue.** Don't repeat the same feedback on multiple occurrences — comment on the first and note "same pattern at lines X, Y, Z" if needed.
- **Every line is a liability.** Apply the ricotta-reducer mindset: if code doesn't justify its existence, it's weight. Flag wrappers that add no logic, abstractions with one implementation, and docstrings that restate the function name.
- **Prioritize findings.** Lead with what matters most. Not everything is equally important.
- **Be honest about uncertainty.** If something's purpose is unclear, say so in "Questions to Consider" — don't flag it as an issue.
