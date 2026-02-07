---
name: code-review
description: Comprehensive code review of a library, system, or whole repo with persistent review history.
argument-hint: "[module or class to focus on, or leave blank for full overview]"
---

Perform a comprehensive code review of this codebase. This is a deep architectural walkthrough, not a line-by-line diff review.

## Phase 1: Review History

First, check for previous reviews:

1. Run `ls -t .claude/review/*.md 2>/dev/null | head -1` to find the most recent review document.
2. If a previous review exists:
   - Read it to understand what was covered last time.
   - Extract the git commit SHA from the review metadata (stored in the frontmatter).
   - Run `git log --oneline <previous_sha>..HEAD` to show what changed since the last review.
   - Run `git diff --stat <previous_sha>..HEAD` to show which files changed.
   - Present a concise **Delta Summary** to the user:
     - Number of commits since last review
     - Key files/areas that changed
     - Any new modules or deleted modules
   - Ask: "Would you like me to focus the review on what changed, or do a fresh full walkthrough?"
3. If no previous review exists, note this is the first review of the codebase.

## Phase 2: Scope Selection

Ask the user ONE question with these options:

- **Outside-in overview** - Start from entry points, map the full architecture, then drill into each layer
- **Focus on a specific module/class** - Deep dive into a particular area (user specifies which)
- **Delta-only review** - Only review what changed since the last review (only if a previous review exists)

If the user provided an argument ($ARGUMENTS), use that as the focus area and skip this question.

## Phase 3: Discovery

Use the gouda-explorer agent (or explore directly) to map the codebase:

1. **Identify the core business models/domain objects.** These are the nouns of the system - the entities that the code exists to serve. List them prominently. Everything else in the review should reference back to these.

2. **Map the system architecture:**
   - Entry points (main, handlers, CLI, API routes)
   - Core domain layer (business models, rules, transformations)
   - Infrastructure/adapters (databases, HTTP clients, file I/O)
   - Configuration and bootstrapping

3. **Trace key flows** through the system. For each significant flow, describe it in business terms:
   > "This module takes a {BusinessModelX} and transforms it into the {ExternalRequest} needed to fulfill {BusinessRequirementY}."

## Phase 4: The Review

Structure the review around business concepts, not file trees. For each major area:

### 4a. Business Model Inventory
- What are the core domain objects?
- Are they well-defined with clear invariants?
- Do they model the real-world concepts they represent?
- Are they pure (free of infrastructure concerns)?

### 4b. Architecture Assessment
- How does data flow through the system?
- Where are the boundaries between business logic and infrastructure?
- Are dependencies pointing in the right direction?
- Is there a clear public API / entry point for each module?

### 4c. Code Quality Signals
For each module or significant area, assess:
- **Coupling**: How entangled is this with other modules?
- **Cohesion**: Does this module have a single clear responsibility?
- **Naming**: Do names reflect business concepts or technical jargon?
- **Error handling**: Fail fast and loud, or silent swallowing?
- **Complexity**: Any functions/files exceeding complexity budget (40 lines/fn, 300 lines/file)?

### 4d. Risk Areas
- Where are the likely sources of bugs?
- What would break if requirements change?
- Are there hidden assumptions or implicit contracts?
- Any security concerns (input validation, injection, secrets)?

### 4e. Strengths
- What patterns are working well?
- What would you keep exactly as-is?

## Phase 5: Persist the Review

After completing the review, save it:

1. Create the directory if needed: `mkdir -p .claude/review`
2. Generate a filename: `YYYY-MM-DD-HHMMSS.md` (use current timestamp)
3. Write the review document with this structure:

```markdown
---
date: YYYY-MM-DDTHH:MM:SSZ
commit: <current HEAD sha>
scope: <"full" | "delta" | specific module name>
previous_review: <filename of previous review, or "none">
---

# Code Review: <project name>

## Business Models
<list of core domain objects identified>

## Architecture Overview
<high-level architecture description>

## Module Reviews
<per-module findings, each referencing back to business models>

## Risk Areas
<prioritized list>

## Strengths
<what's working well>

## Recommendations
<prioritized action items>
```

4. Add `.claude/review/` to `.gitignore` if not already present (these are personal review artifacts, not project code).
5. Tell the user where the review was saved.

## Key Principles

- **Always frame in business terms.** Never say "this function processes data." Say "this function converts a {CustomerOrder} into the {FulfillmentRequest} that the warehouse API expects."
- **Reference the core business models constantly.** They are the anchor of the review. Every module should be explained in terms of what it does to/with/for those models.
- **Be honest about what you don't understand.** If a module's purpose is unclear, say so - that's a finding in itself.
- **Prioritize findings.** Not everything is equally important. Lead with what matters most.
- **Keep it scannable.** Use headers, bullet points, and short paragraphs. This document should be useful to skim months later.
