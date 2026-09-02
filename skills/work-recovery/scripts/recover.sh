#!/usr/bin/env bash
# recover.sh <sessionId> — reconstruct one session's working state:
# goal prompts, files touched, last verified state, last actions.
# SESSIONS_DB overrides the database path and disables auto-ingest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../session-analytics/scripts/db-path.sh"
DB="$(sessions_db_path)"

[[ $# -ge 1 ]] || { echo "usage: recover.sh <sessionId>" >&2; exit 2; }
SESSION="$1"
S="${SESSION//\'/\'\'}"

ensure_db() {
    if [[ -z "${SESSIONS_DB:-}" ]]; then
        if [[ ! -f "$DB" || -z "$(find "$DB" -mmin -60 2>/dev/null)" ]]; then
            local ingest="$SCRIPT_DIR/../../session-analytics/scripts/ingest.py"
            if [[ -f "$ingest" ]]; then python3 "$ingest" >/dev/null 2>&1 || true; fi
        fi
    fi
    if [[ ! -f "$DB" ]]; then
        echo "No session database at $DB — no logs ingested yet. Nothing to recover."
        exit 0
    fi
    local n
    n="$(duckdb -init /dev/null "$DB" -noheader -list -c \
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'tool_uses'" 2>/dev/null || echo 0)"
    if [[ "$n" != 1 ]]; then
        echo "Session database at $DB has no ingested tables. Nothing to recover."
        exit 0
    fi
}

run() { duckdb -init /dev/null "$DB" -markdown -c "$1" 2>/dev/null || echo "(query failed)"; }

ensure_db

echo "## Work Recovery: $SESSION"
echo
echo "### Session"
run "SELECT harness, sessionId, project, branch, first_seen, last_seen, entry_count
     FROM sessions WHERE sessionId = '$S';"
echo
echo "### Goal (opening user prompts, chronological — quote, don't paraphrase)"
run "SELECT timestamp, substr(json_extract_string(message, '\$.content'), 1, 300) AS prompt
     FROM raw_entries
     WHERE sessionId = '$S' AND type = 'user' AND message IS NOT NULL
       AND json_type(json_extract(message, '\$.content')) = 'VARCHAR'
     ORDER BY timestamp LIMIT 5;"
echo
echo "### Files touched (reads vs edits/writes)"
run "SELECT file_path,
            sum(CASE WHEN tool_name = 'Read' THEN 1 ELSE 0 END) AS reads,
            sum(CASE WHEN tool_name IN ('Edit','Write','MultiEdit','NotebookEdit') THEN 1 ELSE 0 END) AS writes
     FROM tool_uses
     WHERE sessionId = '$S' AND file_path IS NOT NULL
     GROUP BY file_path ORDER BY writes DESC, reads DESC LIMIT 25;"
echo
echo "### Last verified state (test/build/git commands, latest first)"
run "SELECT timestamp, substr(bash_cmd, 1, 120) AS cmd
     FROM tool_uses
     WHERE sessionId = '$S' AND tool_name = 'Bash' AND bash_cmd IS NOT NULL
       AND (bash_cmd LIKE '%test%' OR bash_cmd LIKE '%build%' OR bash_cmd LIKE '%cargo%'
            OR bash_cmd LIKE '%pytest%' OR bash_cmd LIKE '%bats%' OR bash_cmd LIKE 'git %'
            OR bash_cmd LIKE '%just %')
     ORDER BY timestamp DESC LIMIT 10;"
echo
echo "### Last actions (reverse-chronological — infer the next step)"
run "SELECT timestamp, tool_name,
            coalesce(substr(bash_cmd, 1, 80), file_path, skill_name, agent_type) AS detail
     FROM tool_uses
     WHERE sessionId = '$S'
     ORDER BY timestamp DESC LIMIT 10;"
echo
echo "Empty verified-state table = no test/build/git command recorded; say so plainly."
