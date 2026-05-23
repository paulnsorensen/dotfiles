#!/usr/bin/env bash
# stop hook: append a one-line session summary to ~/.cursor/logs/session-summary.log.
#
# Stays well under 2s — single append, no network. Cursor invokes this on
# session end; failure is fail-open (we exit 0 even if we couldn't write).

set -uo pipefail

log_dir="$HOME/.cursor/logs"
log_file="$log_dir/session-summary.log"

mkdir -p "$log_dir" 2>/dev/null || exit 0

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cwd=${PWD##*/}
printf '%s\t%s\tsession-end\n' "$ts" "$cwd" >> "$log_file" 2>/dev/null || true

exit 0
