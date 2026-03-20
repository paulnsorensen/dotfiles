---
name: code-review
description: Comprehensive code review with persistent history. Spawns fromage-age in comprehensive mode for full architectural audit.
argument-hint: "[module or class to focus on, or leave blank for full overview]"
---

Comprehensive code review of this codebase: $ARGUMENTS

## Instructions

### 1. Check Review History

Check for previous reviews inline (cheap read):

1. Run `ls -t .claude/review/*.md 2>/dev/null | head -1` to find the most recent review.
2. If a previous review exists:
   - Read it for context on what was covered.
   - Extract the git commit SHA from the frontmatter.
   - Run `git log --oneline <previous_sha>..HEAD` and `git diff --stat <previous_sha>..HEAD` to show what changed.
   - Present a **Delta Summary**: commits since last review, key changed files/areas.
3. If no previous review exists, note this is the first review.

### 2. Select Scope

Use AskUserQuestion with these options:
- **Outside-in overview** — Map full architecture, then drill into each layer
- **Focus on a specific module** — Deep dive into a particular area
- **Delta-only review** — Only review what changed since last review (if previous review exists)

If the user provided an argument, use that as focus and skip this question.

### 3. Launch fromage-age (Comprehensive Mode)

```
Task(subagent_type="fromage-age", model="opus", prompt="Comprehensive mode review. Scope: <selected scope>. Delta context: <if delta, include changed files and commit log>. Previous review findings: <if exists, key items from last review>. Review the full architecture: business model inventory, architecture assessment, risk areas, strengths, and scored issues (0-100, surface >= 70).")
```

### 4. Persist the Review

After receiving the report:

1. Create directory: `mkdir -p .claude/review`
2. Write the review to `YYYY-MM-DD-HHMMSS.md` with frontmatter:

```markdown
---
date: YYYY-MM-DDTHH:MM:SSZ
commit: <current HEAD sha>
scope: <"full" | "delta" | specific module name>
previous_review: <filename of previous review, or "none">
---

<fromage-age comprehensive report>
```

3. Add `.claude/review/` to `.gitignore` if not already present.
4. Tell the user where the review was saved.
5. Present findings to the user.
