# Baseline Agent Conventions

Conventions every coding agent in this repo should follow, regardless of language.

- Prefer editing existing files over creating new ones; ask before introducing a new top-level directory.
- Match the existing code style (formatting, naming, error handling) — read a few neighbors before writing.
- Keep changes minimal and reversible: small commits, no drive-by refactors, no speculative abstractions.
- Always run the project's formatter / linter before declaring done.
- If a test suite exists, run the relevant subset before commit; never push red tests intentionally.
