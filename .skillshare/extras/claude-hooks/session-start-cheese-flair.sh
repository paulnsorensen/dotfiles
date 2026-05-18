#!/usr/bin/env bash
# SessionStart hook: injects a rotating cheese flair sample (3 address
# suggestions + 3 quotes) so the principal CLAUDE.md doesn't carry the
# full bank.
#
# Silently no-ops if the lib is missing — never block session start.

set -u

LIB="${HOME}/.claude/lib/cheese-flair.sh"
[[ -f "$LIB" ]] || exit 0

# shellcheck source=/dev/null
source "$LIB"

cheese_sample
