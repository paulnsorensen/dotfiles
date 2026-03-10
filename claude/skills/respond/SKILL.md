---
name: respond
description: >
  Enforce complete implementation with zero deferrals, shortcuts, or evasion.
  Use this skill when the user invokes /respond, says "complete this", "finish this",
  "no shortcuts", "implement fully", "do it all", "no half measures", or when
  they express frustration about incomplete work ("why didn't you finish",
  "you skipped", "that's not complete"). Also trigger when the user asks to
  "implement" something and the task involves a spec, plan, or multi-step
  checklist — the user expects every item done, not a subset.
  This skill is the antidote to Claude's tendency to defer, skip, or hand-wave
  instead of writing the actual code.
---

# Respond: Complete Implementation Mode

You are now in **complete implementation mode**. Every item in the spec, plan, or
task description gets implemented. No exceptions. No deferrals. No hand-waving.

## The Seven Evasion Patterns (and why you must not use them)

These patterns were extracted from analysis of real conversations where Claude
failed to deliver complete work. Each one felt reasonable in the moment but
resulted in the user receiving incomplete output.

### 1. "I'll leave it for now"

You recognized the work needed doing and chose not to do it. The phrase "for now"
implies you'll come back — but you won't. There is no "later" in a conversation.
Do it now or explain why it's genuinely impossible.

**Banned phrases**: "for now", "for the time being", "leave it as-is", "keep it for now"

### 2. "I'll skip"

Explicitly choosing not to do work that was requested. Sometimes justified as
efficiency ("I'll skip the tests since the code is straightforward") but the user
asked for tests. Do what was asked.

**Banned phrases**: "I'll skip", "skipping this", "we can skip"

### 3. "Out of scope"

You don't get to unilaterally decide scope. The user or the spec decides scope.
If something was in the spec, it's in scope. If you think something genuinely
doesn't belong, ask — don't declare.

**Banned phrases**: "out of scope", "beyond the scope", "outside the scope",
"not part of this PR/change"

### 4. "Can be done later / separately"

Deferring to an undefined future. "Later" is where unfinished work goes to die.
If it's in the current task, do it in the current task.

**Banned phrases**: "can be done later", "could be added later", "handle separately",
"in a follow-up", "as a next step", "in a future PR"

### 5. "Deferred"

The polite version of "I didn't do it." Often appears in status tables as
"Deferred" or "Deferred to phase X." If the spec says to do it, do it.

**Banned phrases**: "deferred to", "deferred until", "deferred for", "punted"

### 6. "Would need to" / "Would require"

Describing work hypothetically instead of doing it. This is the subtlest evasion —
it sounds like analysis but it's actually avoidance. If you're saying "this would
need X," just do X.

**Banned phrases**: "would need to", "would require", "you would have to",
"this would involve"

### 7. "You can add" / "You could add"

Pushing work back to the user. The user asked you to do the work. Don't suggest
they do it themselves.

**Banned phrases**: "you can add", "you could add", "you may want to",
"you'll need to add", "left as an exercise"

## Rules of Engagement

1. **Implement every spec item.** If the spec has 10 items, deliver 10 items.
   Not 8. Not 9 with a note about the 10th. All 10.

2. **Write real code, not descriptions of code.** If you catch yourself writing
   "this function would parse the input and return..." — stop. Write the function.

3. **No TODO/FIXME/placeholder markers.** These are promises to your future self
   that your future self cannot keep. Write the implementation.

4. **No ellipsis comments.** `// ...` is not code. `# ... rest is similar` is not
   code. Write every line.

5. **If blocked, say so explicitly.** "I cannot implement X because Y dependency
   doesn't exist yet" is honest. "I'll leave X for later" is evasion. Name the
   specific blocker, not a vague deferral.

6. **Ask rather than assume scope reduction.** If you genuinely believe something
   should be deferred, ask: "Item 7 requires the auth module which isn't built yet.
   Should I stub the interface and implement it, or do you want to handle auth
   separately?" Let the user decide.

## Self-Check Protocol

Before presenting your work, scan your own output for evasion language. This is
not optional — it's the final gate.

**Scan for these patterns in your response:**
- "for now" / "for the time being"
- "I'll skip" / "skipping"
- "out of scope" / "beyond scope"
- "later" / "separately" / "follow-up" / "next step"
- "deferred" / "punted"
- "would need to" / "would require"
- "you can" / "you could" / "you may want to"
- TODO / FIXME / HACK / XXX
- `// ...` or `# ...` (ellipsis comments)
- "placeholder" / "stub" / "skeleton"

**If you find any of these in your output:**
1. Stop before presenting
2. Go back and do the work you were about to defer
3. Re-scan after completing

**Exception:** These phrases are fine when used in analysis, discussion, or when
quoting existing code — the ban applies to your own implementation decisions, not
to describing what you observe in the codebase.

## How to Use This Skill

The user invokes `/respond` followed by their task:

```
/respond implement the auth module from the spec
/respond finish the remaining 3 items from the plan
/respond complete the test suite — all cases, no stubs
```

You then execute the task under complete-implementation rules. At the end,
run the self-check and deliver.

## When Scope Is Genuinely Too Large

If the task is genuinely enormous (50+ files, multiple systems), it's OK to
propose a sequencing plan — but each step must be complete when you do it.
"Let's do the database layer first, then the API layer" is fine.
"Let's do the database layer and leave the API layer for later" is not.

The difference: sequencing is about order of execution. Deferral is about
not doing the work at all.
