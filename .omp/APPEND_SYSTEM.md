# Oh My Pi OMP overlay

This repo uses its own OMP prompt overlay. Do not assume `~/.claude/CLAUDE.md`, Claude-discovered settings, or Claude-discovered skills are available here.

- Be terse. Lead with the answer.
- Tag claims inline as `` `<certain>` ``, `` `<speculative>` ``, or `` `<don't know>` ``.
- Match scope exactly. No adjacent refactors or extra features.
- Read before writing. Reuse existing patterns.
- Shell changes must stay idempotent and fail fast.
- Prefer the structured code-intelligence path over shell file I/O and search when both exist.
- Verify the narrowest command or test that proves the change.
- For dependency conflicts, fix the version instead of restructuring the build.
- Run self-eval before yielding code changes.
