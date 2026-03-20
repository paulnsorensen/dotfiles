# Description Optimization Playbook

The description field determines whether the skill fires at all. Everything
else is irrelevant if the description fails.

## How Routing Works

No embeddings, classifiers, or pattern matchers. All skill descriptions are
formatted into text in the Skill tool's system prompt. Claude's language model
decides which skill matches through its transformer forward pass.

The description is not a summary for humans — it's a trigger specification
for the model.

## The Three-Part Structure

```
[Core capability]. [Secondary capabilities and scope].
Use when [trigger 1], [trigger 2], or when user mentions "[keyword1]",
"[keyword2]". Do NOT use for [anti-trigger 1], [anti-trigger 2].
```

## Before/After Examples

### Report Generator

Before (summary-style — never fires):
```yaml
description: A skill for generating project status reports.
```

After (trigger-style):
```yaml
description: >
  Generate project status reports with metrics, blockers, and next steps.
  Use when the user asks to "write a report," "create a status update,"
  "summarize project progress," or mentions "report," "status," "standup
  summary." Do NOT use for code documentation, API docs, or README files.
```

### PR Review

Before:
```yaml
description: Code review assistance for pull requests.
```

After:
```yaml
description: >
  Analyze pull requests for bugs, security issues, and architectural concerns.
  Use when the user says "review this PR," "check this pull request," "look at
  this diff," "code review," or pastes a GitHub PR URL. Do NOT use for writing
  new code, refactoring, or generating tests — those are implementation tasks.
```

## Rules

1. **Third person always.** "I help with..." creates POV confusion in the
   system prompt. Use "Analyze..." or "Generate..."
2. **Include exact user phrases.** Not abstract capabilities, but literal words:
   "review this PR," "write a report," "deploy to staging."
3. **Be pushy.** Anthropic explicitly recommends this. Over-triggering is easier
   to fix (add anti-triggers) than under-triggering (debug why it never fires).
4. **5-10 trigger keywords.** Include synonyms, abbreviations, casual phrasings.
5. **Negative triggers.** "Do NOT use for..." prevents false activation on
   adjacent tasks. Essential with multiple skills in overlapping domains.
6. **Under ~100 words.** The description loads on EVERY prompt (Stage 1).
7. **Test with realistic prompts.** Not "use the skill" but the kind of messy
   thing a real person types.

## Activation Benchmarks

| Approach | Trigger rate | Cost/prompt |
|----------|-------------|-------------|
| No optimization (baseline) | ~20% | $0.006 |
| Optimized description only | ~50% | $0.006 |
| Description + forced eval hook | ~84% | $0.007 |

For critical skills, pair description optimization with a forced-evaluation
hook. See `hooks-catalog.md` for the implementation.

## Automated Optimization

If you have `claude -p` (Claude Code CLI), use the skill-creator's loop:
1. Create 20 eval queries (10 should-trigger, 10 should-not-trigger)
2. Make should-trigger queries realistic and messy, not clean abstractions
3. Make should-not-trigger queries near-misses, not obviously irrelevant
4. Run: `python -m scripts.run_loop --eval-set evals.json --skill-path path/`

The loop splits 60/40 train/test, evaluates 3x per query, proposes improvements
based on failures, and selects by test score to avoid overfitting.
