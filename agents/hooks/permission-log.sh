#!/usr/bin/env bash
# PermissionRequest / PermissionDenied hook: append the event to
# events.jsonl for observability. The logic lives in the sibling Node module
# (lib/permission-log.js); this bridge exists so the entry deploys as a `.sh`
# that runs correctly whether invoked directly via shebang (the `ap`
# plugin-tree path) or as `bash <path>` (the legacy sync path) — a `.js`
# script entry would break under the latter.
#
# Self-locating (same rationale as tool-reroute.sh): anchor to the deployed
# path so the same file works under ~/.claude's plugin tree.
#
# Fail-open: a missing logic file or absent node must never block a
# permission decision — the hook only observes, it must not become a
# denial-of-service. Stdout is always empty and the exit code always 0.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"  # ~/.claude/plugins/local/<p>
LOGIC="$HARNESS_ROOT/lib/permission-log.js"

[[ -f "$LOGIC" ]] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# exec so the event stdin flows straight through to Node.
exec node "$LOGIC"
