---
name: copilot-review
allowed-tools: Bash(gh *), Bash(git *), Bash(jq *), Bash(cat *), Read, Grep, AskUserQuestion, Task, TaskCreate, TaskUpdate, TaskList, TaskGet
description: Review a PR and route fixes to GitHub Copilot via inline comments. Spawns fromage-age for the review, then formats findings for Copilot.
argument-hint: "<PR number or URL>"
---

Review a pull request and route fixes to GitHub Copilot: $ARGUMENTS

## Progress Tracking

At command start, call `TaskCreate` for all 4 phases. Mark `in_progress` at phase start, `completed` at phase end.

| Phase | Subject | activeForm |
|---|---|---|
| 1 | Fetch PR context | Fetching PR context |
| 2 | Run code review | Running code review |
| 3 | Format findings for Copilot | Formatting review findings |
| 4 | Post review comments | Posting review comments |

## Phase 1: Fetch PR Context (inline — small)

1. Determine the PR number from the argument. If it's a URL, extract the number. If no argument, list open PRs with `gh pr list` and ask which one.

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

5. Present brief summary: PR title, author, base <- head, files changed, additions/deletions.

## Phase 2: Launch fromage-age (Focused Mode)

```
Task(subagent_type="fromage-age", model="opus", prompt="Focused mode review of PR #<number>. Title: <title>. Author: <author>.\n\nDiff:\n<diff content>\n\nReview through two lenses:\n1. Correctness & Safety (security, bugs, silent failures)\n2. Architecture & Weight (coupling, dead code, inline, undocument, complexity)\n\nScore all findings 0-100. Only surface >= 75. For each finding include: file, line, category, issue description, and concrete fix.")
```

## Phase 3: Format Findings for Copilot

When fromage-age returns its scored findings:

1. **Present strengths first** — what the PR does well (not posted as comments).

2. **Present scored findings** grouped by file, adding disposition:

For each finding, assign:
- `COPILOT_FIX` — Straightforward fix Copilot can handle (add validation, fix logic, delete dead code, inline wrapper, remove restating docstring)
- `FUTURE_TASK` — Broader context needed, architectural decision, multi-file refactor

```
### path/to/file.ts

| # | Score | Line | Category | Issue | Disposition |
|---|-------|------|----------|-------|-------------|
| 1 | 95 | 42 | BUG | Null check missing | COPILOT_FIX |
| 2 | 80 | 78 | COUPLING | Domain imports HTTP client | FUTURE_TASK |
```

3. Show the **full comment text** for each item:

**COPILOT_FIX format:**
```
**[CATEGORY]**: Issue description

**Why this matters:** Teaching moment — the principle behind the fix.

@copilot fix this
```

**FUTURE_TASK format:**
```
**[CATEGORY]**: Issue description

**Why this matters:** Teaching moment — the principle behind the suggestion.

_Noted for future work — not a Copilot fix._
```

4. Ask the user:
   - Which comments to **post** (default: all)
   - Which to **skip**
   - Any to **edit** before posting
   - Whether any disposition should change

## Phase 4: Post Comments (after user approval)

1. Build JSON payload for `gh api repos/{owner}/{repo}/pulls/<number>/reviews`:
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

2. Submit via `gh api --method POST --input /tmp/pr-review-payload.json`

3. Display summary: total posted, COPILOT_FIX count, FUTURE_TASK count, PR link.

4. Clean up temp file.

## Rules

- **Never post without user approval**
- **Frame in business terms** — never "this function processes data"
- **One comment per issue** — note "same pattern at lines X, Y, Z" if repeated
- **Respect the codebase** — don't flag consistent patterns
- **All review intelligence lives in fromage-age** — this command handles PR fetch + Copilot formatting only
