#!/usr/bin/env bash
# PreToolUse hook: transparently REWRITE wrong-tool Bash/Grep/Glob calls to their
# tilth / wt-git shell equivalent (via updatedInput), and DELEGATE every other
# Bash command to the harness's rtk hook for token compaction. The detection
# logic lives in the sibling Node module (lib/tool-reroute.js) + its
# lib/tool-reroute/ modules; this bridge exists so the entry deploys as a `.sh`
# that runs correctly whether invoked directly via shebang (the `ap` plugin-tree
# path) or as `bash <path>` (the legacy sync path) — a `.js` script entry would
# break under the latter.
#
# Self-locating (same rationale as git-guard.sh): anchor to the deployed path so
# the same file works under ~/.claude's plugin tree and ~/.codex. `ap` deploys
# this alongside lib/tool-reroute.js + lib/tool-reroute/*.js via shared_assets.
#
# Harness identity: the delegation step shells out to `rtk hook <harness>`, so we
# derive claude/codex from the deploy path (claude lands in a `.../.claude/...`
# plugin tree, codex in `~/.codex/...`) and pass it to the logic as $1.
#
# Fail-open: a missing logic file or absent node must never block a tool call —
# the hook rewrites/hardens, it must not become a denial-of-service.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(dirname "$SCRIPT_DIR")"  # ~/.claude/plugins/local/<p> or ~/.codex
LOGIC="$HARNESS_ROOT/lib/tool-reroute.js"

case "$SCRIPT_DIR" in
  *.codex*) HARNESS=codex ;;
  *) HARNESS=claude ;;
esac

[[ -f "$LOGIC" ]] || exit 0
command -v node >/dev/null 2>&1 || exit 0

# exec so the PreToolUse stdin/stdout flow straight through to Node.
exec node "$LOGIC" "$HARNESS"
