---
name: worktree-find
description: >
  Locate a git worktree under ~/Dev by branch, slug, repo, touched path, open PR,
  or staleness, returning its path + status so you can cd / resume / inspect it.
  Use when asked "where's the worktree for X", "find the worktree touching <path>",
  "which worktree has the open PR for Y", "find stale worktrees", or when
  /worktree-find is invoked. Read-only — it locates, it does not remove.
model: haiku
effort: low
allowed-tools: Bash
---

# worktree-find

Find worktree(s) matching the user's description and report `path` + `status`.

Two layers: the **mechanical** criteria (branch / slug / repo / staleness) are delegated to the `ccw-find` CLI; the **fuzzy** criteria (touched-path, open-PR, vague staleness phrasing) need judgment and external calls, handled here.

## Protocol

### 1. Classify the criterion

- **branch / slug / repo / staleness** → mechanical. Go to step 2.
- **"the one touching `<path>`"** → step 3.
- **"the one with the open PR for X"** → step 4.

### 2. Mechanical search via `ccw-find`

```bash
ccw-find --slug <s>       # dir-name substring
ccw-find --branch <b>     # branch substring
ccw-find --repo <name>    # restrict to repo <name>
ccw-find --stale <days>   # last commit older than <days>
```

Criteria combine (AND). Each match prints `path<TAB><branch> (<age>)`. Report the rows; if exactly one matches, offer the `cd <path>` to resume.

### 3. Touched-path search

List candidate worktrees first (`ccw-find --root ~/Dev` with any narrowing flag, or `git worktree list` per repo), then inspect each for the path the user named:

```bash
git -C <wt> diff --name-only HEAD            # uncommitted touches
git -C <wt> log --name-only --oneline <default>..HEAD   # committed touches
git -C <wt> ls-files -- '<path-glob>'        # tracked files matching
```

Return the worktree(s) whose diff or commits touch `<path>`, with path + branch + age.

### 4. Open-PR search

```bash
gh pr list --repo <owner/repo> --state open --json number,headRefName,title,url
```

Match the PR's `headRefName` to a worktree branch (use `ccw-find --branch <headRefName>` or `git worktree list`). Return the worktree path for that branch plus the PR number/URL.

## Output

For each match:

```
<path>
  branch: <branch>   age: <relative>   <extra: PR #, touched files>
```

When one worktree matches unambiguously, end with the resume hint: `cd <path>` (or `ccw <repo>/<slug> --resume`).

## Rules

- Read-only — never remove, commit, or modify a worktree. Cleanup is `/worktree-sweep`; teardown is `ccw-rm`.
- Prefer `ccw-find` for the mechanical criteria; only hand-roll git/gh for touched-path and open-PR.
- If nothing matches, say so plainly and show what was searched (root, criteria) — do not guess a path.
