---
applyTo: "**"
excludeAgent: "coding-agent"
---

## Code Review Focus

Focus reviews on these categories, in priority order:

1. **Security** — Flag hardcoded secrets, API keys, tokens, passwords, or credentials in any file
2. **Silent failures** — Flag empty catch blocks, swallowed errors, missing error handling on I/O operations
3. **Complexity violations** — Flag functions over 40 lines, files over 300 lines, nesting deeper than 3 levels
4. **Consistency** — Flag patterns that contradict established conventions in the codebase
5. **CLAUDE.md quality** — When `CLAUDE.md` or `claude/CLAUDE.md` is in the diff, verify changes are consistent with the tool division (tilth is the default for search/edit/read/deps/callers; LSP is gated to planning-only via the `cheese-flow:explore-lsp` sub-agent invoked through `/explore`)

## CLAUDE.md Validation

When any `CLAUDE.md` file is modified, check:

- Key Commands section documents all new commands/aliases
- Architecture section reflects actual directory structure
- Skill Delegation table matches the skills in `claude/skills/`
- No duplicate information between `CLAUDE.md` (project) and `claude/CLAUDE.md` (global)
- Complexity Budget numbers are consistent across all files

## Claude Skill Validation

When any `claude/skills/*/SKILL.md` is modified, check:

- `allowed-tools` lists only tools the skill actually uses
- `description` accurately describes when to invoke the skill
- Tool division is respected (no skill claims capabilities belonging to another tool)
- Examples use correct syntax for the tool (e.g., `tilth_search kind: regex` patterns, `tilth_edit` line:hash anchors; direct LSP ops should only appear inside `cheese-flow:explore-lsp` docs)

## What NOT to Comment On

- ShellCheck issues — handled by pre-commit hooks (prek)
- Formatting and whitespace — handled by pre-commit hooks
- Import ordering — not applicable to shell/config files
- Missing docstrings on internal functions
- Style preferences consistent with the rest of the codebase
- Nitpicks with no functional impact

## Review Style

- Only comment when confidence is high
- If a pattern is used consistently elsewhere in the codebase, do not flag it
- Suggest specific fixes, not vague improvements
- One comment per issue — do not repeat the same feedback across files
