---
name: commit
model: sonnet
allowed-tools: Bash(git:*)
description: >
  Stage and commit changes to git following conventional commits format. Use
  when asked to commit, create a commit, or save changes. Drafts meaningful
  commit messages by understanding the why, not just the what. Never amends
  published commits, never skips hooks, never uses git add -A. Stages specific
  files by name. Does not push — that is the gh skill's job.
---

# commit

Stage and commit. Conventional commits. No push.

## Protocol

Run in parallel first:

```bash
git status
git diff HEAD
git log --oneline -5
```

Then sequentially:

1. **Understand the why** — read the diff, understand what changed and why
2. **Stage specific files** — by name, never `git add -A` or `git add .`
3. **Draft the message** — see format below
4. **Commit** via heredoc (preserves formatting)
5. **Verify** with `git status`

## Commit message format

```
type(scope): short description (≤72 chars)

Optional body if nuance is lost without it.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`

Focus on the **why**, not the **what**. The diff already shows what changed.

## Heredoc template

```bash
git commit -m "$(cat <<'EOF'
type(scope): description

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

## Rules

- **Never amend** unless explicitly asked — create new commits instead
- **Never --no-verify** — don't skip hooks
- **Never force-push** to main/master
- **No push, no PR** — hand off to gh skill for that
- **Hook fails?** Fix the issue, re-stage, create a new commit (not amend)
- **Don't commit** `.env`, credentials, or large binaries — warn the user
