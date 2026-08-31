#!/usr/bin/env bash
# snapshot.sh [ccw-sweep flags...] — ccw-sweep --dry-run distilled for triage:
# ANSI stripped, SAFE rows dropped. Survivors: repo headers (only for repos
# with WARN/DIRTY worktrees), WARN/DIRTY entries with reasons and nested-child
# relocation warnings, skipped-repo notices, and the summary block.
set -euo pipefail

esc="$(printf '\033')"

ccw-sweep --dry-run "$@" \
    | sed -E "s/${esc}\[[0-9;]*m//g" \
    | awk '
        / worktree\(s\), default: / { hdr = $0; skip = 1; next }
        /^  \[SAFE\]/               { skip = 1; next }
        /^  \[(WARN|DIRTY)\]/       { if (hdr != "") { print hdr; hdr = "" } skip = 0; print; next }
        /^         /                { if (!skip) print; next }
        /skipping$/                 { print; next }
        /^No worktrees found/       { print; next }
        /^Summary:/                 { print ""; print; insum = 1; next }
        insum && /^  /              { print; next }
    '
