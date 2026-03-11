---
name: warn-ellipsis-code
enabled: true
event: file
conditions:
  - field: new_text
    operator: regex_match
    pattern: (//\s*\.\.\.|#\s*\.\.\.|/\*\s*\.\.\.\s*\*/|\.{3}\s*(rest|remaining|similar|same))
action: warn
---

**Ellipsis/lazy code detected.**

You are writing ellipsis comments or "rest is similar" hand-waves instead of actual code. This is the most common form of spec evasion.

Write the actual code. Every line. No shortcuts. If the pattern truly repeats, use a loop or function — don't leave `// ...` for the user to fill in.
