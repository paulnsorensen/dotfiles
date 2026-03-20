---
name: gh
model: haiku
context: fork
allowed-tools: mcp__plugin_github_github__*, Bash(git:*), Bash(gh:*), Bash(gh-pr-review:*), Bash(gh-pr-prep:*), Bash(gh-issue-context:*), Bash(gh-pr-batch:*), Bash(gh-pr-checks-batch:*)
description: >
  Complete GitHub tasks using the GitHub MCP plugin. Use for any GitHub operation —
  PRs, issues, CI checks, repo management, releases, code search.
  Use git commands (log, diff, status) for local context.
  Prefer MCP tools over gh CLI — they bypass sandbox/TLS issues.
  Use when the user says "create PR", "merge PR", "check CI", "list issues", "review PR",
  "PR status", "close issue", or invokes /gh. Do NOT use for local git operations like
  commit, stage, or push — use /commit for those.
examples:
  - "review PR 14"
  - "create a PR for my branch"
  - "what's the CI status on this PR?"
  - "list open issues labeled bug"
  - "merge PR 23 with squash"
  - "gather context for PR 14"
  - "show me issue 42 with comments"
---

# gh

GitHub operations via **GitHub MCP plugin** (`mcp__plugin_github_github__*`). MCP is the default — it works reliably in sandbox with no TLS issues.

**Default**: GitHub MCP tools for all supported operations.
**Fallback**: `gh` CLI only for operations MCP doesn't cover (see table below).
**Rule**: `git` is read-only here — log, diff, status. No commits, no push via git.

---

## MCP Tool Reference

### Pull Requests

| Operation | MCP Tool |
|-----------|----------|
| Create PR | `create_pull_request` (title, body, head, base) |
| List PRs | `list_pull_requests` (state, head, base filters) |
| Read PR | `pull_request_read` (number) |
| Merge PR | `merge_pull_request` (number, merge_method) |
| Update PR | `update_pull_request` (title, body, state) |
| Update branch | `update_pull_request_branch` (number) |
| Review PR | `pull_request_review_write` (approve, request_changes, comment) |
| Reply to comment | `add_reply_to_pull_request_comment` |
| Search PRs | `search_pull_requests` (query) |

### Issues

| Operation | MCP Tool |
|-----------|----------|
| Create issue | `issue_write` |
| List issues | `list_issues` (state, labels, assignee) |
| Read issue | `issue_read` (number) |
| Edit issue | `issue_write` (update mode) |
| Comment | `add_issue_comment` (number, body) |
| Search issues | `search_issues` (query) |
| Sub-issues | `sub_issue_write` |

### Repos & Code

| Operation | MCP Tool |
|-----------|----------|
| Create repo | `create_repository` |
| Fork repo | `fork_repository` |
| List branches | `list_branches` |
| Create branch | `create_branch` |
| List commits | `list_commits` |
| Get commit | `get_commit` (sha) |
| File contents | `get_file_contents` (path) |
| Create/update file | `create_or_update_file` |
| Push files | `push_files` (multiple files in one commit) |
| Delete file | `delete_file` |
| Search code | `search_code` (query) |
| Search repos | `search_repositories` (query) |

### Releases & Tags

| Operation | MCP Tool |
|-----------|----------|
| List releases | `list_releases` |
| Latest release | `get_latest_release` |
| Release by tag | `get_release_by_tag` |
| List tags | `list_tags` |
| Get tag | `get_tag` |

### Other

| Operation | MCP Tool |
|-----------|----------|
| Who am I | `get_me` |
| Get label | `get_label` |
| Teams | `get_teams`, `get_team_members` |
| Issue types | `list_issue_types` |
| Copilot | `assign_copilot_to_issue`, `create_pull_request_with_copilot`, `request_copilot_review`, `get_copilot_job_status` |

---

## CLI Rules

**Never pipe `gh` output.** The `gh` CLI has `--json`, `--jq`, and `--template` flags built in:

```bash
# WRONG — pipe triggers compound command detection + needs jq binary
gh pr list --json number | jq '.[].number'

# RIGHT — inline jq, no pipe, embedded interpreter
gh pr list --json number --jq '.[].number'

# Complex filtering
gh pr list --json number,title,state --jq '.[] | select(.state == "OPEN") | .title'

# Go template alternative
gh pr view 42 --json title --template '{{.title}}'
```

**Never use heredoc `--body` with `gh pr create`.** The `$(cat <<'EOF' ... EOF)` pattern triggers Claude Code's "hides arguments" heuristic when the body contains `#`-prefixed lines (markdown headers).

Instead:
1. **MCP** (preferred): `create_pull_request` — no shell involved
2. **`--body-file`** (CLI fallback): Write body with the Write tool to `$TMPDIR/pr-body.md`, then `gh pr create --title "..." --body-file "$TMPDIR/pr-body.md"`

**Never use `gh api`.** Raw API calls bypass MCP and hit TLS issues in the sandbox. Every `gh api` call has an MCP equivalent:

```bash
# WRONG — TLS failure in sandbox, requires dangerouslyDisableSandbox
gh api repos/owner/repo/pulls/78/reviews

# RIGHT — MCP tool, runs in host process, no sandbox issues
pull_request_read(method: "get_review_comments", owner, repo, pullNumber: 78)
```

If you need an endpoint the MCP doesn't cover, use the `/gh` skill which routes through MCP first and only falls back to CLI for the gaps listed below.

---

## CLI Fallback (only when MCP can't do it)

These operations have no MCP equivalent — use `gh` CLI:

| Operation | Command |
|-----------|---------|
| PR diff | `gh pr diff <number>` |
| PR checks / CI status | `gh pr checks <number>` |
| Run logs | `gh run view <id> --log-failed` |
| Watch a run | `gh run watch <id>` |
| Trigger workflow | `gh workflow run <workflow>` |
| Create release | `gh release create <tag>` |
| Delete release | `gh release delete <tag>` |
| Raw API calls | `gh api <endpoint>` |
| Re-run failed CI | `gh run rerun <id> --failed` |

---

## Batched Recon (CLI)

**Dependency**: Shell helpers (`gh-pr-review`, `gh-pr-prep`, `gh-issue-context`) are defined in `zsh/claude.zsh`.

For gathering PR context where you need diff + checks + metadata in one shot, the shell helpers are efficient:

```bash
gh-pr-review 14              # single PR: metadata + diff + checks
gh-pr-prep                    # commits, diff stat, upstream status
gh-issue-context 42           # issue body + comment thread
gh-pr-batch 59 60 61 62       # batch: metadata + files for multiple PRs
gh-pr-checks-batch 59 60 61   # batch: CI checks for multiple PRs
```

**Batch helpers** (`gh-pr-batch`, `gh-pr-checks-batch`) are designed for `/cheese-convoy` — one bash approval covers all PRs instead of N individual calls. Output includes file paths touched per PR for overlap detection.

---

## Git Context (read-only)

Before creating PRs or writing descriptions, use git for local context:

```bash
git log --oneline origin/main..HEAD   # commits going into the PR
git diff origin/main...HEAD           # full diff for PR body
git status                            # working tree state
```

## What You Don't Do

- Commit, push, rebase, or modify the local working tree — use /commit for git write operations
- Review code quality — use /age or /code-review
- Create worktrees — use /worktree

## Gotchas

- MCP auth tokens can expire mid-session — if MCP calls start failing, restart Claude Code
- `gh` CLI has TLS issues in sandboxed environments — prefer MCP tools
- Heredoc `--body` with markdown headers triggers the "# hides arguments" safety heuristic — use `--body-file` or MCP instead
- Rate limits hit harder on large repos with many PRs — batch operations where possible
