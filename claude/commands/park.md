---
name: park
description: Save session context to Serena memories before exiting. Use when done for the day, switching tasks, or before a clean reset.
---

Park the current session — persist important context to Serena memories so the next session can pick up where this one left off.

## Steps

1. **Summarize the session** — What was worked on, what was accomplished, what's still pending or blocked

2. **Call prepare_for_new_conversation**
   - Serena writes a structured summary memory file automatically
   - Do NOT manually write_memory for session state — this tool is purpose-built for it

3. **If architecture decisions or gotchas were discovered this session:**
   - `write_memory("arch-<topic>.md")` or `write_memory("gotcha-<topic>.md")`
   - Follow naming convention (see `claude/skills/serena/SKILL.md#memory-naming`)

4. **Cleanup:** Call `list_memories`. If count > 5, delete_memory on oldest or redundant entries
   - Ask user before deleting `arch-*` or `gotcha-*` memories
   - Note: `session-*` files are auto-managed by `prepare_for_new_conversation`

5. **Confirm what was saved** — Report to user
   - Tell them to `/exit` then run `ccfresh` to start primed
   - Next session will auto-activate Serena and load memories
