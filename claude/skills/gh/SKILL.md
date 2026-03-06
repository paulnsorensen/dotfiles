---
name: gh
model: haiku
fork: true
allowed-tools: mcp__plugin_github_github__*, Bash(gh:*), Bash(git:*), Bash(gh-pr-review:*), Bash(gh-pr-prep:*), Bash(gh-issue-context:*)
description: >
  Complete GitHub tasks using only the gh CLI. Use for any GitHub operation —
  PRs, issues, CI checks, repo management, releases, Actions, code search.
  Use git commands (log, diff, status) for context when informing GitHub
  operations (e.g. reading commits before drafting a PR body). Never use the
  GitHub REST API directly or browser URLs. Only gh commands.
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

GitHub operations via GitHub MCP plugin or `gh` CLI. Use `git` read-only commands for context.

**Prefer**: GitHub MCP tools (`mcp__plugin_github_github__*`) — works in sandbox, no TLS issues.
**Fallback**: `gh` CLI when MCP tools don't cover the operation (e.g., `gh run watch`, `gh release`).
**Rule**: `git` is read-only here — log, diff, status. No commits, no push.

---

## Batched operations

**Dependency**: Shell helpers (`gh-pr-review`, `gh-pr-prep`, `gh-issue-context`) are defined in `zsh/claude.zsh` — if that file is reorganized, update the references here.

Batch multiple gh/git calls into a single Bash invocation to minimize round-trips.
Shell helpers are available in `zsh/claude.zsh` for the most common bundles.

```bash
# PR review — metadata + diff + checks in one shot
gh-pr-review 14

# PR prep — commits, diff stat, upstream status before creating a PR
gh-pr-prep

# Issue context — issue body + full comment thread
gh-issue-context 42
```

When helpers don't cover your case, batch manually:

```bash
# Custom batch — collect related data in one script
{
  echo "=== PR METADATA ==="
  gh pr view 14 --json number,title,state,author,additions,deletions
  echo "=== DIFF ==="
  gh pr diff 14
  echo "=== CHECKS ==="
  gh pr checks 14
}
```

---

## Pull requests — `gh pr`

**PR bodies**: Always write the body to a temp file and use `--body-file` instead of inline `--body`.
Inline markdown with `#` headers triggers Claude Code's safety check ("newline followed by #-prefixed line").

```bash
BODY_FILE=$(mktemp)
printf '%s\n' "## Summary" "Description here..." > "$BODY_FILE"
gh pr create --title "type(scope): description" --body-file "$BODY_FILE"
rm -f "$BODY_FILE"
```

| Command | What it does |
|---------|-------------|
| `gh pr create` | Open a PR (`--title`, `--body-file`, `--base`) |
| `gh pr list` | List open PRs; filter with `--state`, `--label`, `--search` |
| `gh pr view [<number>]` | Read PR body and metadata |
| `gh pr diff [<number>]` | Show the diff |
| `gh pr checks [<number>]` | CI status for all checks |
| `gh pr review [<number>]` | Approve, request changes, or comment |
| `gh pr merge [<number>]` | Merge (`--merge`, `--squash`, `--rebase`) |
| `gh pr edit [<number>]` | Update title, body, labels, assignees |
| `gh pr comment [<number>]` | Add a comment |
| `gh pr checkout [<number>]` | Check out branch locally |
| `gh pr ready [<number>]` | Mark draft as ready for review |
| `gh pr close / reopen` | Change state |

---

## Issues — `gh issue`

| Command | What it does |
|---------|-------------|
| `gh issue create` | File an issue |
| `gh issue list` | List issues; filter with `--state`, `--label`, `--assignee` |
| `gh issue view [<number>]` | Read issue body and metadata |
| `gh issue edit [<number>]` | Update title, body, labels, assignees |
| `gh issue comment [<number>]` | Add a comment |
| `gh issue close / reopen` | Change state |
| `gh issue develop [<number>]` | Create/link a branch to the issue |

---

## Repos, Actions, Releases

```bash
# Repos
gh repo view [<repo>]        # metadata
gh repo create               # new repo
gh repo fork                 # fork current repo
gh repo edit                 # update settings

# Actions
gh run list                  # recent runs
gh run view [<id>]           # run details
gh run watch [<id>]          # stream logs
gh workflow run <workflow>   # trigger dispatch

# Releases
gh release list
gh release create <tag>      # add --notes, --draft, --prerelease
gh release view [<tag>]
gh release delete <tag>
```

---

## Raw API — `gh api`

```bash
gh api repos/{owner}/{repo}/topics               # GET
gh api repos/{owner}/{repo}/issues -f title="X"  # POST
gh api --paginate /repos/{owner}/{repo}/issues   # paginate
gh api graphql -f query='{ viewer { login } }'  # GraphQL
gh api repos/{owner}/{repo}/releases --jq '.[0].tag_name'
```

---

## Output and flags

```bash
# Extract structured data
gh pr list --json number,title,headRefName --jq '.[] | "\(.number)\t\(.title)"'
gh pr view --json number,title,state,url

# Common flags
-R / --repo owner/repo   # target a different repo
--limit N                # cap results
--web                    # open in browser
```

## Git context (read-only)

Before creating PRs or writing descriptions, use git for context:

```bash
git log --oneline origin/main..HEAD   # commits going into the PR
git diff origin/main...HEAD           # full diff for PR body
git status                            # working tree state
```
