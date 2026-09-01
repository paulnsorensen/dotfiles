#!/usr/bin/env bash
# query.sh <report> [harness] | sql "SELECT ..." — canned session-log reports.
# Reports: tools errors mcp skills sessions bash denials allowlist-gaps
#          python3 hooks compound projects heatmap
# Harness: all (default) | claude | codex | omp | cursor | copilot
# sql runs one raw query against the database (markdown output).
# SESSIONS_DB overrides the database path and disables auto-ingest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${SESSIONS_DB:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/session-analytics/sessions.duckdb}"
[[ "$DB" = /* ]] || DB="$PWD/$DB"

usage() {
    sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

[[ $# -ge 1 ]] || usage
REPORT="$1"
if [[ "$REPORT" == sql ]]; then
    [[ $# -ge 2 ]] || usage
    RAW_SQL="$2"
    HARNESS="all"
else
    HARNESS="${2:-all}"
fi

hf() { [[ "$HARNESS" == all ]] || printf "AND %sharness = '%s'" "${1:-}" "${HARNESS//\'/\'\'}"; }

ensure_db() {
    if [[ -z "${SESSIONS_DB:-}" ]]; then
        if [[ ! -f "$DB" || -z "$(find "$DB" -mmin -60 2>/dev/null)" ]]; then
            if [[ -f "$SCRIPT_DIR/ingest.py" ]]; then
                python3 "$SCRIPT_DIR/ingest.py" >/dev/null 2>&1 || true
            fi
        fi
    fi
    if [[ ! -f "$DB" ]]; then
        echo "No session database at $DB — no logs ingested yet."
        exit 0
    fi
    local n
    n="$(duckdb -init /dev/null "$DB" -noheader -list -c \
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'tool_uses'" 2>/dev/null || echo 0)"
    if [[ "$n" != 1 ]]; then
        echo "Session database at $DB has no ingested tables."
        exit 0
    fi
}

run() { duckdb -init /dev/null "$DB" -markdown -c "$1" 2>/dev/null || echo "(query failed)"; }

ensure_db

case "$REPORT" in
    sql)
        duckdb -init /dev/null "$DB" -markdown -c "$RAW_SQL"
        ;;
    tools)
        run "SELECT tool_name, count(*) AS uses
             FROM tool_uses WHERE 1=1 $(hf)
             GROUP BY tool_name ORDER BY uses DESC;"
        ;;
    errors)
        run "SELECT tu.tool_name, count(*) AS total,
                    sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) AS errors,
                    round(sum(CASE WHEN tr.is_error = 'true' THEN 1 ELSE 0 END) * 100.0 / count(*), 1) AS error_pct
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE 1=1 $(hf tu.)
             GROUP BY tu.tool_name ORDER BY errors DESC;"
        ;;
    mcp)
        run "SELECT split_part(tool_name, '__', 2) AS server,
                    split_part(tool_name, '__', 3) AS method, count(*) AS calls
             FROM mcp_calls WHERE 1=1 $(hf)
             GROUP BY server, method ORDER BY calls DESC;"
        ;;
    skills)
        run "SELECT skill_name, timestamp::DATE AS day, count(*) AS uses
             FROM skill_invocations WHERE 1=1 $(hf)
             GROUP BY skill_name, day ORDER BY day DESC, uses DESC;"
        ;;
    sessions)
        run "SELECT s.sessionId, s.project, s.branch, s.first_seen, s.last_seen,
                    (SELECT count(*) FROM tool_uses tu WHERE tu.sessionId = s.sessionId) AS tool_calls
             FROM sessions s WHERE 1=1 $(hf s.)
             ORDER BY tool_calls DESC LIMIT 10;"
        ;;
    bash)
        run "SELECT substr(bash_cmd, 1, 80) AS cmd, count(*) AS uses
             FROM tool_uses
             WHERE tool_name = 'Bash' AND bash_cmd IS NOT NULL $(hf)
             GROUP BY cmd ORDER BY uses DESC LIMIT 20;"
        ;;
    denials)
        run "SELECT
                 CASE
                     WHEN bash_cmd LIKE '%python3%' THEN 'python3 inline'
                     WHEN bash_cmd LIKE '%cat %' AND bash_cmd LIKE '%>%' THEN 'cat redirect (use Write)'
                     WHEN bash_cmd LIKE 'find %' OR bash_cmd LIKE '% find %' THEN 'find (use Glob)'
                     WHEN bash_cmd LIKE 'grep %' OR bash_cmd LIKE 'egrep %' THEN 'grep (use Grep)'
                     WHEN bash_cmd LIKE 'sed %' OR bash_cmd LIKE '%sed -i%' THEN 'sed (use Edit)'
                     WHEN bash_cmd LIKE 'cd %' AND bash_cmd LIKE '%git%' THEN 'cd+git (use wt-git)'
                     WHEN bash_cmd LIKE 'cd %' AND bash_cmd LIKE '%gh %' THEN 'cd+gh (use wt-git)'
                     WHEN bash_cmd LIKE '%cargo clippy%' THEN 'cargo clippy'
                     WHEN bash_cmd LIKE '%cargo fmt%' THEN 'cargo fmt'
                     WHEN bash_cmd LIKE '%cargo nextest%' THEN 'cargo nextest'
                     WHEN bash_cmd LIKE '%just %' THEN 'just'
                     WHEN bash_cmd LIKE '%tokei%' THEN 'tokei'
                     WHEN bash_cmd LIKE 'mkdir%' THEN 'mkdir'
                     WHEN bash_cmd LIKE '%git add%&&%git commit%' THEN 'git add+commit (use /commit)'
                     WHEN bash_cmd LIKE '%git commit%\$(%' THEN 'git commit heredoc (use /commit)'
                     ELSE 'other: ' || substr(bash_cmd, 1, 50)
                 END AS category,
                 count(*) AS denials
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE tu.tool_name = 'Bash' AND tr.is_error = 'true'
               AND tr.content LIKE 'Permission to use Bash%' $(hf tu.)
             GROUP BY category ORDER BY denials DESC;"
        ;;
    allowlist-gaps)
        run "SELECT split_part(bash_cmd, ' ', 1) AS cmd_prefix, count(*) AS uses,
                    sum(CASE WHEN tr.is_error = 'true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) AS denied,
                    round(sum(CASE WHEN tr.is_error = 'true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) * 100.0 / count(*), 1) AS deny_pct
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL $(hf tu.)
             GROUP BY cmd_prefix HAVING count(*) >= 5
             ORDER BY denied DESC LIMIT 20;"
        ;;
    python3)
        run "SELECT
                 CASE
                     WHEN bash_cmd LIKE '%json.load%' OR bash_cmd LIKE '%json.loads%' THEN 'JSON parse/transform'
                     WHEN bash_cmd LIKE '%json.dump%' OR bash_cmd LIKE '%json.dumps%' THEN 'JSON write'
                     WHEN bash_cmd LIKE '%json.tool%' THEN 'JSON pretty-print'
                     WHEN bash_cmd LIKE '%re.sub%' OR bash_cmd LIKE '%re.match%' OR bash_cmd LIKE '%.replace(%' THEN 'regex/string replace'
                     WHEN bash_cmd LIKE '%open(%' AND bash_cmd LIKE '%write%' THEN 'file write/update'
                     WHEN bash_cmd LIKE '%open(%' AND bash_cmd LIKE '%read%' THEN 'file read/filter'
                     WHEN bash_cmd LIKE '%base64%' THEN 'base64 encode/decode'
                     WHEN bash_cmd LIKE '%yaml%' THEN 'YAML processing'
                     WHEN bash_cmd LIKE '%subprocess%' THEN 'subprocess orchestration'
                     WHEN bash_cmd LIKE '%os.path%' OR bash_cmd LIKE '%import os%' THEN 'filesystem ops'
                     WHEN bash_cmd LIKE '%import re%' THEN 'regex processing'
                     ELSE 'other'
                 END AS purpose,
                 count(*) AS cnt,
                 round(count(*) * 100.0 / sum(count(*)) OVER (), 1) AS pct
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE tu.tool_name = 'Bash' AND tu.bash_cmd LIKE '%python3%'
               AND tr.is_error = 'false' $(hf tu.)
             GROUP BY purpose ORDER BY cnt DESC;"
        ;;
    hooks)
        run "SELECT level, preventedContinuation,
                    substr(stopReason, 1, 100) AS reason, count(*) AS cnt
             FROM stop_hooks WHERE 1=1 $(hf)
             GROUP BY level, preventedContinuation, reason
             ORDER BY cnt DESC LIMIT 20;"
        ;;
    compound)
        run "SELECT substr(bash_cmd, 1, 150) AS cmd, count(*) AS denials
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE tu.tool_name = 'Bash' AND tr.is_error = 'true'
               AND tr.content LIKE 'Permission to use Bash%'
               AND (bash_cmd LIKE '%|%' OR bash_cmd LIKE '%&&%') $(hf tu.)
             GROUP BY cmd ORDER BY denials DESC LIMIT 20;"
        ;;
    projects)
        run "SELECT regexp_extract(cwd, '.*/([^/]+)\$', 1) AS project,
                    tool_name, count(*) AS uses
             FROM tool_uses WHERE 1=1 $(hf)
             GROUP BY project, tool_name ORDER BY project, uses DESC;"
        ;;
    heatmap)
        run "SELECT timestamp::DATE AS day,
                    extract(hour FROM timestamp::TIMESTAMP) AS hour, count(*) AS calls
             FROM tool_uses
             WHERE timestamp::DATE >= CURRENT_DATE - INTERVAL '14' DAY $(hf)
             GROUP BY day, hour ORDER BY day DESC, hour;"
        ;;
    *)
        echo "Unknown report: $REPORT" >&2
        usage
        ;;
esac
