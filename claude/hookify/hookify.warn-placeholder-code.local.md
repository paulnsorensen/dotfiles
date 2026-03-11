---
name: warn-placeholder-code
enabled: true
event: file
conditions:
  - field: new_text
    operator: regex_match
    pattern: (TODO|FIXME|HACK|XXX|PLACEHOLDER|unimplemented!|todo!)\b
action: warn
---

**Placeholder detected in written code.**

You are writing code with TODO/FIXME/placeholder markers instead of a real implementation. This is spec evasion — implement it now or explain why you can't.

Do not:
- Leave TODO comments as promises to yourself
- Write `unimplemented!()` or `todo!()` stubs
- Add FIXME markers for known issues you should fix now

If the implementation is genuinely blocked by something outside your control, state the specific blocker clearly.
