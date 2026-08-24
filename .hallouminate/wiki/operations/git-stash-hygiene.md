# Git stash hygiene in the dotfiles repo

The `~/Dev/dotfiles` working tree persistently carries several *unrelated* WIP
stashes (e.g. `opencode-lean-prewarm WIP`, `local-llm WIP`, `affinage-recovery`).
A bare `git stash pop` therefore applies `stash@{0}` — usually someone else's
WIP — into your tree, often with conflict markers.

**Why it bites.** A cure once tried to isolate pre-existing test failures with
`git stash push -- <files>` then `git stash pop`. The push silently no-op'd
because the target files were *untracked* (a pathspec matches nothing untracked),
and the bare pop then applied an unrelated `stash@{0}`, contaminating
`tests/local-llm.bats` with conflict markers.

**How to work safely.**

- Never `git stash pop` without a ref. Pop only a stash you created, by exact
  ref: `git stash pop stash@{n}`.
- Untracked files don't stash via pathspec — move or copy them instead.
- To stage a clean tree for verification, prefer `git stash create` + an explicit
  ref, or just revert the working-tree edits directly.
- Recover from accidental contamination with `git checkout HEAD -- <file>`; a
  *conflicted* pop does not drop the stash, so the original WIP stays safe.

Related: [[just-check-claude-guard-flake]] — the other repo-local trap during a
completion gate.
