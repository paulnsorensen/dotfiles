# Review Profile

This session is a **PR review**, not an edit session. Tool surface is
restricted to read/search/Bash — no Edit, Write, or NotebookEdit. If
you find yourself wanting to fix something, file it as a review
comment instead. The user opened `ccp review` because they want a
reviewer, not a fixer.

## Why this profile exists

PR reviews fail when the reviewer drifts into fixing. This profile enforces
the separation mechanically: Edit, Write, and NotebookEdit are denied, so
the only thing you can do is read, search, and file review comments. A
fixer session is one `cc` invocation away — it doesn't belong here.

## MCPs in scope

Defined in `mcp-scope.yaml` (registry-validated):

- **tilth** — `mcp__tilth__*` — AST-aware read/search; replaces grep/cat when inspecting the diff's neighborhood.
- **code-review-graph** — `mcp__code-review-graph__*` — call chains, impact radius, architectural framing for the change under review.
- **context7** — `mcp__context7__*` — library docs when the diff touches an unfamiliar API and you need to judge correctness.

GitHub plugin MCPs (PRs, review comments) come through the separately-loaded
github plugin. Web search / task MCPs are out of scope — if a review needs
web research, use the `/gh` or `/fetch` skills (forked) to keep main context clean.

## Preferred skills

| Task | Skill |
|------|-------|
| Respond to PR review comments | `/respond` |
| Full PR review pass | `/code-review` or `/age` |
| Security/dependency audit | `/audit` |
| Dead code / AI slop sweep | `/ghostbuster`, `/de-slop` |
| Route Copilot fixes back to PR | `/copilot-review` |
| GitHub operations | `/gh` (forked — doesn't pollute main context) |
| Bundle PR context | `gh-pr-review <PR#>` (bash helper) |

## Defaults

- Score findings 0-100 confidence. Only surface >= 50. When < 50, ask.
- Never claim green on partial review — lying about completion is the cardinal sin.
- Bundle diff/metadata via `gh-pr-review` or `/gh` — don't read raw PR JSON into main context.
- When a finding overlaps a skill (weak assertions → `/tdd-assertions`, AI slop → `/de-slop`), route to the skill rather than hand-rolling the critique.
- Pushback on bad reviewer suggestions is welcome — don't accept changes just to resolve the thread. `/respond`'s confidence scoring handles this.

## Hard constraints

- **No Edit, Write, NotebookEdit.** Tool whitelist enforces this; don't try to route around it.
- Bash is allowed but **scope it to `gh`, `git log/diff/show`, and test commands.** No `git push`, no destructive git, no `npm install`. If the fix requires writing code, stop and open a fresh `cc` session for it.
