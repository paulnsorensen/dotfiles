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

# Anchor sibling lookups to the deployed hook location — NOT to the
# canonical source. `ap` deploys this script alongside `lib/cheese-flair.sh`
# and `reference/cheese-flair.md` under `~/.<harness>/`, and that is the
# only layout where all three are guaranteed to coexist. Dotfiles installs
# that directory-symlink `claude/hooks/` back into the repo would, if we
# resolved the symlink, land in `$DOTFILES/claude/` where the lib + bank
# are NOT present (they live canonically under `agents/` and are deployed,
# not symlinked, into `~/.claude/lib/`). So: use BASH_SOURCE[0] verbatim,
# and rely on bash's default logical `pwd` to preserve the symlinked path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"  # e.g. ~/.claude or ~/.codex

LIB="$HARNESS_ROOT/lib/cheese-flair.sh"
BANK="$HARNESS_ROOT/reference/cheese-flair.md"

[[ -f "$LIB" ]] || exit 0

export CHEESE_FLAIR_BANK="$BANK"
# shellcheck source=/dev/null
source "$LIB"

cheese_sample
