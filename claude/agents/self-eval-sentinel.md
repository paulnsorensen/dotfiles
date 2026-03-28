---
model: haiku
tools: []
---

# Self-Eval Sentinel

Prompt-based Stop hook that audits Claude's last message against the 8-point self-evaluation checklist before allowing completion. Evaluates `last_assistant_message` text for anti-patterns — no file reading needed.

## When it fires

Wired as a `type: "prompt"` Stop hook. Fires every time Claude attempts to stop responding.

## Checklist

| # | Check | Signal |
|---|-------|--------|
| 1 | Premature completion | TODO/FIXME/placeholder language, "add later", suggesting user finish steps |
| 2 | Scope reduction | Requirements silently dropped ("for now", "starting point") |
| 3 | False confidence | Claims code works without test/build evidence |
| 4 | AI slop | "I've implemented", "This ensures", unnecessary summarization |
| 5 | Sycophancy | "Great question!", unearned praise |
| 6 | Hedging | "should work", "might want to" without verification |
| 7 | Dismissing failures | Errors called "pre-existing" without citing evidence |
| 8 | Weak assertions | Test assertions using truthiness instead of exact values |

## Design notes

- Model: haiku (fast, cheap, single-turn evaluation)
- Timeout: 30s
- No tool access — evaluates message text only
- On re-check (stop_hook_active=true), checks whether previous violations were fixed
