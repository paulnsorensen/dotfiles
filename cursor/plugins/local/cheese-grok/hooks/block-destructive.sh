#!/usr/bin/env bash
# beforeShellExecution hook: hard-block obviously destructive shell commands.
#
# Cursor invokes this with the candidate shell command on stdin (single line)
# or as the first argument depending on version. We just need to be safe
# either way and exit 2 (= deny) if matched, 0 otherwise.
#
# The matcher in hooks.json already filters to commands that look destructive;
# this is a second-line confirmation in case the matcher loosens.

set -euo pipefail

read -r cmd <<<"${1:-$(cat)}"

case "$cmd" in
    *"rm -rf "*|*"sudo "*|*"chmod 777"*|*"git push --force"*|*"git reset --hard"*)
        printf 'cheese-grok: blocked destructive command: %s\n' "$cmd" >&2
        exit 2
        ;;
esac

exit 0
