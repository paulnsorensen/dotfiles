---
name: merge-resolve
model: sonnet
context: fork
allowed-tools: Bash(git:*), Bash(mergiraf:*), Bash(python3:*), Read, Edit, Glob
description: >
  Resolve merge conflicts, rebase conflicts, and cherry-pick failures using mergiraf
  (AST-aware structural merge), git rerere, and kdiff3. Activate when: merge failed,
  rebase conflict, cherry-pick failed, CONFLICT in file, "resolve conflicts", "fix merge",
  "merge conflict", "conflict resolution", or git output shows CONFLICT markers.
  Also use for mergiraf diagnostics, rerere management, gitattributes regeneration,
  or batch conflict resolution across multiple files. Covers the full resolution
  chain: mergiraf (structural auto-resolve) → rerere (replay remembered fixes) →
  kdiff3 (manual). Do NOT use for general git operations without conflicts — those
  go to the commit or gh skills.
---

# merge-resolve

Resolve merge conflicts using the structural merge chain: mergiraf → rerere → kdiff3.

## Resolution Chain

The three tools form a cascade — each handles what the previous couldn't:

1. **mergiraf** runs automatically as a git merge driver. It parses all three file versions
   (base, ours, theirs) into Tree-sitter ASTs and merges structurally. Independent additions
   (imports, functions, struct fields) merge cleanly even when text-based merge would conflict.
   Falls back to text merge if parsing fails — never makes things worse.

2. **rerere** ("reuse recorded resolution") activates after mergiraf. If you manually resolved
   the same conflict before, rerere replays that resolution automatically. Especially valuable
   during long rebases where the same conflict recurs across commits.

3. **kdiff3** is the manual fallback for conflicts neither tool could resolve. Launch with
   `git mergetool` — it opens a 3-way diff view for human decision-making.

## Protocol

Note: `<skill-dir>` refers to the directory containing this SKILL.md file.

### 1. Diagnose the Conflict State

Run the summary script first — it replaces the need for `grep -n '<<<<<<<'` and ad-hoc parsers:

```bash
python3 <skill-dir>/scripts/conflict-summary.py
```

This outputs for each conflicted file:

- Language, mergiraf support status, number of hunks
- Each hunk with line numbers, ours/theirs/base content, and surrounding context
- Actionable recommendation (which script to use)

For JSON output (scripting): `--json`. For more context: `--context 10`.

If you need raw git info too:

```bash
git log --merge --oneline            # What commits are involved?
```

### 2. Attempt Structural Resolution

For files where mergiraf is configured but conflicts remain (meaning the structural merge
already ran and couldn't fully resolve), you can inspect what mergiraf produced vs text merge:

```bash
# Extract the 3-way inputs from git's stage slots
git show :1:<path> > /tmp/base    # Stage 1 = common ancestor
git show :2:<path> > /tmp/ours    # Stage 2 = current branch (HEAD)
git show :3:<path> > /tmp/theirs  # Stage 3 = incoming branch

# Preview what mergiraf would produce (writes to -o, doesn't touch working copy)
mergiraf merge /tmp/base /tmp/ours /tmp/theirs -o /tmp/merged -p <path>
# Check if clean (no conflict markers)
grep -c '<<<<<<' /tmp/merged  # 0 = clean
```

If the merged output has no conflict markers, mergiraf resolved it cleanly — the git
merge driver may have fallen back to text merge due to a parse error or size limit.
Apply the clean output:

```bash
cp /tmp/merged <path>
git add <path>
```

### 3. Batch Resolution

For repos with many conflicted files, use the batch script:

```bash
# Preview what can be resolved (no file changes)
python3 <skill-dir>/scripts/batch-resolve.py --dry-run

# Apply all clean resolutions
python3 <skill-dir>/scripts/batch-resolve.py --apply

# With mergiraf debug output
python3 <skill-dir>/scripts/batch-resolve.py --dry-run --verbose
```

The script extracts 3-way inputs for every conflicted file, runs `mergiraf merge`
on them, and reports which files resolved cleanly vs which need manual intervention.

### 4. Handle Remaining Conflicts

After structural resolution, for files that still have conflict markers:

**Check rerere first:**

```bash
git rerere status    # Files with recorded resolutions
git rerere diff      # Show what rerere would apply
```

If rerere has a resolution, it was already applied. If not, guide the user to manual resolution:

```bash
git mergetool        # Opens kdiff3 for each conflicted file
# Or for a specific file:
git mergetool <path>
```

After manual resolution:

```bash
git add <resolved-files>
# Then continue the interrupted operation:
git merge --continue    # or
git rebase --continue   # or
git cherry-pick --continue
```

### 5. Debug Mergiraf

When mergiraf isn't resolving something you expect it to:

```bash
# Run with debug logging to see parse results and matching decisions
RUST_LOG=mergiraf=debug mergiraf merge /tmp/base /tmp/ours /tmp/theirs -o /tmp/merged -p <path> 2>&1

# Check if the file type is registered
mergiraf languages | grep <extension>

# Verify gitattributes
git check-attr merge -- <path>
# Should show: <path>: merge: mergiraf
```

Common issues:

- **File not registered**: Extension missing from `~/.gitattributes` — regenerate after upgrade
- **Parse failure**: Syntax error in one of the three versions — mergiraf falls back silently
- **Size limit**: Very large files (>1MB) may skip structural merge — check with `--size-limit`

### 6. Maintenance Commands

**Regenerate gitattributes after mergiraf upgrade:**

```bash
mergiraf languages --gitattributes > ~/.gitattributes
```

**Manage rerere state:**

```bash
git rerere status          # What's currently being tracked
git rerere diff            # Pending resolution diffs
git rerere forget <path>   # Forget a bad resolution for one file
git rerere gc              # Clean old entries (default: 60 days unresolved, 15 days resolved)
ls .git/rr-cache/          # Browse the resolution database
```

## Scripts

Four scripts and a shared utility module in `<skill-dir>/scripts/` cover the common patterns:

| Script | Purpose | When to use |
|--------|---------|-------------|
| `conflict-summary.py` | Structured summary with line numbers + context | **Always run first** — replaces grep for `<<<<<<<` |
| `batch-resolve.py` | Run `mergiraf merge` on all conflicted files | Supported langs with structural conflicts |
| `conflict-pick.py` | Choose ours/theirs per hunk | Shell, SQL, `.gitignore`, or formats not handled by mergiraf (e.g. Markdown without a `.gitattributes` entry) |
| `lockfile-resolve.py` | Take one side + regenerate lockfile | `Cargo.lock`, `package-lock.json`, `yarn.lock`, etc. |
| `git_utils.py` | Shared utilities — conflict detection, mergiraf support check | Internal — imported by other scripts |

**conflict-pick.py** — for file types not handled by mergiraf in this repo (shell scripts, `.gitignore`, or Markdown when `.md` isn't registered in `.gitattributes`):

```bash
# Take ours for all hunks
python3 <skill-dir>/scripts/conflict-pick.py hooks/session-start.sh --ours

# Take theirs for all hunks
python3 <skill-dir>/scripts/conflict-pick.py .gitignore --theirs

# Prompt per hunk (interactive)
python3 <skill-dir>/scripts/conflict-pick.py hooks/runner.sh --interactive

# Take ours only for hunks matching a pattern (leave others as conflicts)
python3 <skill-dir>/scripts/conflict-pick.py config.yaml --grep "timeout" --ours
```

**lockfile-resolve.py** — the `cargo.lock` pattern from real sessions: take theirs, regenerate:

```bash
# Auto-detect conflicted lockfiles and regenerate (default: theirs + regen)
python3 <skill-dir>/scripts/lockfile-resolve.py

# Just regenerate if manifest is already resolved
python3 <skill-dir>/scripts/lockfile-resolve.py --strategy regen

# Preview
python3 <skill-dir>/scripts/lockfile-resolve.py --dry-run
```

Supports: `Cargo.lock`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`,
`poetry.lock`, `Pipfile.lock`, `uv.lock`, `Gemfile.lock`, `go.sum`.

## Special Cases

### Lockfiles

Lockfiles need special handling — textual or structural merge produces valid syntax
but potentially invalid dependency graphs. Use `lockfile-resolve.py` (see Scripts above).
The proven pattern (from session history): take `--theirs` on the lockfile, then
regenerate from the merged manifest. Works for Cargo.lock, package-lock.json, yarn.lock,
poetry.lock, uv.lock, go.sum, and more.

### Whitespace-Only Formatting Changes

If one branch ran a formatter (rustfmt, prettier) while the other modified content,
mergiraf may produce more conflicts than text merge because AST positions shifted.
Resolution: run the formatter on the merged result after resolving conflicts.

### Abort if Stuck

If the conflict state is unrecoverable:

```bash
git merge --abort     # or
git rebase --abort    # or
git cherry-pick --abort
```

## Reference

For the full mergiraf CLI reference, supported languages, troubleshooting guide,
and performance tips, read `<skill-dir>/references/mergiraf-guide.md`.

## What This Skill Doesn't Do

- **Push or create PRs** — hand off to the gh skill
- **Run builds or tests** — use the make or test skills after resolving
- **Commit resolved files** — use the commit skill
- **Architectural review of merge results** — use age or code-review
- **Abort the operation** — presents abort as an option, user decides

## Gotchas

- `mergiraf solve` flag confusion: use `--stdout`/`-p` for preview, NOT `--output` (that's for `mergiraf merge`)
- Markdown is supported by mergiraf but historically ignored in sessions — trust it, let it run
- Lockfile structural merge != valid lockfile — always regenerate after taking a side
- zdiff3 base markers: files may contain `|||||||` sections — all scripts handle it but custom parsers must account for it
- If you see conflicts in a supported file type, mergiraf-as-driver already ran — use manual re-run via stage slots to diagnose

## Output

The skill agent aggregates results across all scripts and reports a unified summary:

- Files conflicted: N
- Resolved (mergiraf): N
- Resolved (conflict-pick): N
- Resolved (lockfile-regen): N
- Remaining: N

If remaining > 0: list files + next action. If 0: "All resolved. Continue with git merge/rebase/cherry-pick --continue"
