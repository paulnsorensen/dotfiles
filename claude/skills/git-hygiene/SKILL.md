---
name: git-hygiene
description: >
  Guardrail for proper git tool usage. Prevents reading file contents via
  git show <ref>:<path> or git cat-file, which bypass the Read tool and
  file access controls. This skill triggers automatically when planning
  to use git show, git cat-file, or when needing to read files from other
  branches or commits. Also triggers when you catch yourself about to
  construct a "git show ref:path" command.
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
| Read a file as it was at a specific commit | `git checkout <ref> -- <path>`, then **Read** the file, then `git checkout HEAD -- <path>` to restore |
| View commit metadata | `git show <commit>` (no colon — this is fine) |
| View commit stats | `git show --stat <commit>` (fine) |
| List files changed in a commit | `git diff-tree --no-commit-id -r <commit>` (fine) |

## Why this matters

- **Read tool** lets the user see what you're reading and control access
- **git show ref:path** is invisible to file access guards
- Raw file dumps pollute context — diffs are almost always more useful
- Worktree files are already available via Read — no git gymnastics needed
