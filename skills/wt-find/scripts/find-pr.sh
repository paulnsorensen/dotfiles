#!/usr/bin/env bash
# find-pr.sh [wt-find flags...] — join open GitHub PRs to local worktrees by
# head branch. Extra flags narrow the candidate set via wt-find; with none,
# all worktrees under ~/Dev are candidates. One `gh pr list` per unique origin.
# Output per match: path<TAB>branch<TAB>PR #<n><TAB><title><TAB><url>
set -euo pipefail

# shellcheck source=skills/wt-find/scripts/find-pr-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/find-pr-lib.sh"
find_pr_main "$@"
