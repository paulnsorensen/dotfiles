# Cloud routines live in their own repo

All five Claude Code cloud routines live in the **private `paulnsorensen/routines`**
repo (moved there 2026-08-09), *not* in the repos they act on. Layout:
`routines/<name>/{routine.md,sources.yaml}`, `bin/<name>-scan`,
`tests/<name>-scan.bats`. The five are `doc-drift`, `wiki-harvest`, `dep-harvest`,
`tilth-upstream`, and `wiki-update-tdbr`.

**Why.** dotfiles and tilth each hosted routines that mostly acted on *other*
repos, so prompts, manifests, and scanners were scattered across three trees with
no shared test suite. Consolidating gives one home and one suite; dotfiles and
tilth now only *reference* the routines.

**Edit them there, not here.** Two consequences that are easy to miss:

- A routine that acts on a different repo than it lives in must say so — each such
  prompt opens with a "Two repos" section. Scanners that run `git` need the target
  checkout passed in explicitly (`bin/tilth-upstream-scan <path>`); the old
  `cd $(dirname $0)/..` idiom silently measures the wrong tree.
- `doc-drift`'s `reconciled` markers now live in a different repo from the dotfiles
  pins they track, so the two drift independently and no test catches a mismatch
  (the old `packages.bats` assertion was deliberately dropped).
