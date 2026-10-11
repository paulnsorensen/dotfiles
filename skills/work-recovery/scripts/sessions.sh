#!/usr/bin/env bash
# sessions.sh [project] [harness] — recent-session shape, for picking a
# recovery target. project is a cwd substring ('%' / omitted = all).
# Harness: all (default) | claude | codex | omp | cursor | copilot
# SESSIONS_DB selects an existing package-compatible database without refresh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skills/session-analytics/scripts/report-lib.sh
source "$SCRIPT_DIR/../../session-analytics/scripts/report-lib.sh"

PROJECT="${1:-%}"
HARNESS="${2:-all}"
P="${PROJECT//\'/\'\'}"

hf() { [[ "$HARNESS" == all ]] || printf "AND %sharness = '%s'" "${1:-}" "${HARNESS//\'/\'\'}"; }

run() { sessions_package_sql_markdown "$1"; }

echo "## Session Shape: $PROJECT  (harness=$HARNESS)"
echo
echo "### Recent sessions (most recent first)"
run "SELECT harness, sessionId,
            regexp_extract(project, '.*/([^/]+)\$', 1) AS proj,
            branch, first_seen, last_seen, entry_count
     FROM sessions
     WHERE project LIKE '%$P%' $(hf)
     ORDER BY last_seen DESC LIMIT 20;"
echo
echo "### Busiest (by tool calls)"
run "SELECT s.sessionId,
            regexp_extract(s.project, '.*/([^/]+)\$', 1) AS proj,
            (SELECT count(*) FROM tool_uses tu WHERE tu.sessionId = s.sessionId) AS tool_calls
     FROM sessions s
     WHERE s.project LIKE '%$P%' $(hf s.)
     ORDER BY tool_calls DESC LIMIT 20;"
echo
echo "No rows = no sessions match; do not invent."
