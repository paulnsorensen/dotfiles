---
name: git-hygiene
user-invocable: false
description: >
  Guardrail for proper git tool usage. Prevents reading file contents via
  git show <ref>:<path> or git cat-file, which bypass the Read tool and file
  access controls. Triggers when planning git commands that read file contents
  from other branches or commits, or when colon syntax appears in git commands.
  Use when about to construct "git show ref:path" or "git cat-file" commands.
  Do NOT use for normal git operations like commit, push, log, or diff.
---

# git-hygiene

Git has commands that can read arbitrary file contents from any branch or commit.
Using them in Bash bypasses the Read tool, avoids file access controls, and floods
the context window with unstructured output. This skill explains why these
patterns are dangerous and what to do instead.

## Blocked patterns

**`git show <ref>:<path>`** — reads raw file contents from any ref.
```
git show origin/main:src/lib.rs          # blocked
git show HEAD~3:package.json             # blocked
git show abc123:Cargo.toml               # blocked
```

**`git cat-file -p <ref>:<path>`** — same thing, lower-level plumbing.

The colon (`:`) is the tell — it means "file contents at ref", not "commit details".

## What to do instead

| Goal | Correct approach |
|------|-----------------|
| Read a file in the current worktree | Use the **Read** tool directly |
| Compare a file across versions | `git diff <ref> -- <path>` (shows diff, not raw content) |
| See what changed in a file between refs | `git diff <ref> HEAD -- <path>` (shows delta, not raw content) |
| Read a file from another branch in isolation | Use **Read** tool after switching branches via `/worktree` — isolated worktree is the safe pattern |
| View commit metadata | `git show <commit>` (no colon — this is fine) |
| View commit stats | `git show --stat <commit>` (fine) |
| List files changed in a commit | `git diff-tree --no-commit-id -r <commit>` (fine) |

## Why this matters

- **Read tool** lets the user see what you're reading and control access
- **git show ref:path** is invisible to file access guards
- Raw file dumps pollute context — diffs are almost always more useful
- Worktree files are already available via Read — no git gymnastics needed

## Gotchas

- `git log -p` and `git show <commit>` (without path) are safe — they show diffs, not file contents
- `git diff <ref> -- <path>` is safe — shows delta, doesn't bypass Read tool
- The colon syntax (`ref:path`) is the specific pattern to block — not all `git show` usage
- Sub-agents may not have this skill loaded — the companion hook is the real enforcement
