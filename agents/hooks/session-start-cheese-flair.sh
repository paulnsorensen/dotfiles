#!/usr/bin/env bash
# SessionStart hook: inject a rotating cheese flair sample (3 address
# suggestions + 3 quotes) so the principal agents-doc doesn't carry the
# full bank.
#
# Self-locating: resolves the lib and bank relative to the script's own
# deployed path so the same file works under ~/.claude/ and ~/.codex/.
#
# Silently no-ops if the lib is missing — never block session start.

set -u

# BSD readlink (macOS default) lacks -f, but Claude / Codex always invoke
# this script via its real ~/.{harness}/hooks/ path — no symlink hops to
# resolve. Use $BASH_SOURCE[0] directly, fall through to `readlink -f` only
# when it's available (GNU coreutils on Linux).
_src="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    _resolved=$(readlink -f "$_src" 2>/dev/null) && _src="$_resolved"
fi
SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"  # e.g. ~/.claude or ~/.codex

LIB="$HARNESS_ROOT/lib/cheese-flair.sh"
BANK="$HARNESS_ROOT/reference/cheese-flair.md"

[[ -f "$LIB" ]] || exit 0

export CHEESE_FLAIR_BANK="$BANK"
# shellcheck source=/dev/null
source "$LIB"

cheese_sample
