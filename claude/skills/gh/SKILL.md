---
name: gh
model: haiku
allowed-tools: Bash(gh:*), Bash(git:*)
description: >
  Complete GitHub tasks using only the gh CLI. Use for any GitHub operation —
  PRs, issues, CI checks, repo management, releases, Actions, code search.
  Use git commands (log, diff, status) for context when informing GitHub
  operations (e.g. reading commits before drafting a PR body). Never use the
  GitHub REST API directly or browser URLs. Only gh commands.
---

# gh

GitHub operations via `gh` CLI. Use `git` read-only commands for context.

**Rule**: Only `gh` for GitHub tasks. `gh api` when no dedicated subcommand exists.
**Rule**: `git` is read-only here — log, diff, status. No commits, no push.

---

## Pull requests — `gh pr`

| Command | What it does |
|---------|-------------|
| `gh pr create` | Open a PR (`--title`, `--body`, `--base`) |
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
