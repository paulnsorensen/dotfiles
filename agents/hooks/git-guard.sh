#!/usr/bin/env bash
# PreToolUse hook: block destructive git ops (`git checkout -- <path>`,
# `git restore`, `git reset --hard`, `git clean -f`, `git checkout .`/`-f`)
# when the targeted paths have uncommitted changes. The detection logic lives
# in the sibling Node module (lib/git-guard.js); this bridge exists so the
# entry deploys as a `.sh` that runs correctly whether invoked directly via
# shebang (the `ap` plugin-tree path) or as `bash <path>` (the legacy sync
# path) — a `.js` script entry would break under the latter.
#
# Self-locating (same rationale as session-start-cheese-flair.sh): anchor to
# the deployed path so the same file works under ~/.claude and the plugin
# tree. `ap` deploys this script alongside lib/git-guard.js via the registry's
# `shared_assets`.
#
# Fail-open: a missing logic file or absent node must never block a git op —
# the guard hardens, it must not become a denial-of-service.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"  # e.g. ~/.claude or the plugin root
LOGIC="$HARNESS_ROOT/lib/git-guard.js"

[[ -f "$LOGIC" ]] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# exec so the PreToolUse stdin/stdout flow straight through to Node.
exec node "$LOGIC"
