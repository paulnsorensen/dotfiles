# Archive

Retired agent instructions, skills, and slash commands, kept for reference. Nothing here deploys—`dots sync` only reads the live source directories.

Content is archived when a newer workflow supersedes it or live instructions consolidate it:

| Archived | Superseded by | Notes |
|---|---|---|
| `claude-commands/spec.md` | `/mold` | Same triggers ("spec this out", "plan this feature"); `/cheese` routes spec-shaping to /mold |
| `spec-verify/` | `/age` (spec dimension) + `/verify` | Only consumer was mold's curdle pass, which soft-depends and skips silently when absent |
| `claude-commands/move-my-cheese.md` | `/affinage` | PR takeover (comments + CI + conflicts + push) is /affinage's scope |
| `claude-commands/cheese-convoy.md` | — | Multi-PR fan-out of move-my-cheese; no exact replacement for "consolidate open PRs", but dead once move-my-cheese retired |
| `agents-rules.md` | consolidated live `Rules` block | Verbatim copy of the 13 global rules before consolidation |

Removed outright in the same change (thin wrappers, recoverable from git
history): `/duck` (→ `/culture`), `/wreck` (→ `/press`), `/test`
(→ whey-drainer agent), `/worktree-sweep` (→ `worktree-triage` + `ccw-sweep`),
`/copilot-review` `/copilot-delegate` `/copilot-setup` (→ `/copilot` modes).
