---
name: park
description: Save session context to Serena memories before exiting. Use when done for the day, switching tasks, or before a clean reset.
---

Park the current session — persist important context to Serena memories so the next session can pick up where this one left off.

## Steps

1. **Summarize the session** — What was worked on, what was accomplished, what's still pending or blocked

2. **Write to Serena memory** — Use `write_memory` with filename `session-context.md`:
   - Current task / feature being worked on
   - Key files modified or under investigation
   - Decisions made and approaches chosen
   - Next steps / TODOs
   - Any gotchas or blockers discovered

3. **Confirm saved** — Report what was written to memory

4. **Instruct the user** — Tell them to `/exit` then run `ccfresh` to start a clean primed session
