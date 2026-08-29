#!/usr/bin/env bash
# pr-create.sh <worktree-path> <title> [gh pr create flags...] — PR body on
# stdin. Pushes HEAD, writes the body to a temp file, runs
# `gh pr create --body-file`. Exists because heredoc PR bodies trip Claude
# Code's "# hides arguments" heuristic and `cd <path> && git` trips another.
set -euo pipefail

path="${1:?usage: pr-create.sh <worktree-path> <title> [gh flags...] < body.md}"
title="${2:?usage: pr-create.sh <worktree-path> <title> [gh flags...] < body.md}"
shift 2

body="$(mktemp "${TMPDIR:-/tmp}/prbody.XXXXXX")"
trap 'rm -f "$body"' EXIT
cat >"$body"

git -C "$path" push -q -u origin HEAD
(cd "$path" && gh pr create --title "$title" --body-file "$body" "$@")
