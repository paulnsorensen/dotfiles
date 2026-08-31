#!/usr/bin/env bash
# create.sh [-o|-m] <slug> — create or resume a task worktree via `wt` (bin/),
# then translate its JSON into the human confirmation the worktree skill reports.
#   -m (default): branch off the current branch   -o: branch off origin/<default>
set -euo pipefail

json="$(wt "$@")"
jq -r '
  "Worktree \(if .created then "ready" else "resumed" end): \(.path)",
  "Branch: \(.branch)",
  "Base: \(.base_sha) (\(.base_branch))"
' <<<"$json"
