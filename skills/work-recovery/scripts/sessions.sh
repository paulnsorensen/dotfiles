#!/usr/bin/env bash
# sessions.sh [project] [harness] — recent-session shape, for picking a
# recovery target. project is a cwd substring ('%' / omitted = all).
# Harness: all (default) | claude | codex | omp | cursor | copilot
# SESSIONS_DB overrides the database path and disables auto-ingest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../session-analytics/scripts/db-path.sh"
DB="$(sessions_db_path)"

PROJECT="${1:-%}"
HARNESS="${2:-all}"
P="${PROJECT//\'/\'\'}"

hf() { [[ "$HARNESS" == all ]] || printf "AND %sharness = '%s'" "${1:-}" "${HARNESS//\'/\'\'}"; }

ensure_db() {
    if [[ -z "${SESSIONS_DB:-}" ]]; then
        if [[ ! -f "$DB" || -z "$(find "$DB" -mmin -60 2>/dev/null)" ]]; then
            local ingest="$SCRIPT_DIR/../../session-analytics/scripts/ingest.py"
            if [[ -f "$ingest" ]]; then python3 "$ingest" >/dev/null 2>&1 || true; fi
        fi
    fi
    if [[ ! -f "$DB" ]]; then
        echo "No session database at $DB — no logs ingested yet. No sessions to recover."
        exit 0
    fi
    local n
    n="$(duckdb -init /dev/null "$DB" -noheader -list -c \
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'sessions'" 2>/dev/null || echo 0)"
    if [[ "$n" != 1 ]]; then
        echo "Session database at $DB has no ingested tables. No sessions to recover."
        exit 0
    fi
}

run() { duckdb -init /dev/null "$DB" -markdown -c "$1" 2>/dev/null || echo "(query failed)"; }

ensure_db

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
