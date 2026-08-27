# Shared-checkout branch contention between concurrent agent sessions

The dotfiles checkout at `~/Dev/dotfiles` is shared mutable state: multiple
agent sessions run git operations in it concurrently, and any of them can
move HEAD between another session's `git switch -c` and its `git commit`.

Observed 2026-08-17 (HEAD reflog evidence): session A created
`sliced-bread-skills`; session B then checked out
`docs/mise-precedence-rewrite`; session A's commit (`e6efcb76`) landed on
B's branch, A's `push origin sliced-bread-skills` pushed the stale branch
ref, and the resulting PR was empty ("No commits between main and branch").
B's branch permanently carries A's commit as a parent.

Rules that prevent this:

- Never rely on a branch checked out in an earlier command still being
  current. Verify `git branch --show-current` in the same compound command
  as the commit, or commit immediately after `switch -c` with nothing in
  between.
- Prefer a dedicated worktree (`/worktree`, `/wt-git`) for any dotfiles
  branch work — worktrees have private HEADs and are immune to this.
- Recovery when it happens: the commit is intact under its sha; repoint the
  intended branch with `git switch -C <branch> <sha>` and re-push. Do not
  rewrite the other session's branch — it may be live.
