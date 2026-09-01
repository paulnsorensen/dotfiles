#!/usr/bin/env bash
# analyze.sh <domain|all> <target> [harness] — tool-efficiency analytics digests.
# Domains: tool-usage error-forensics fix-recommendations permission-friction
#          mcp-health token-economics
# Target: a tool name (Bash, Read), a Bash command prefix, an MCP server name
#         for mcp-health, or '%' to scan everything.
# Harness: all (default) | claude | codex | omp | cursor | copilot
# SESSIONS_DB overrides the database path and disables auto-ingest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${SESSIONS_DB:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/session-analytics/sessions.duckdb}"
[[ "$DB" = /* ]] || DB="$PWD/$DB"

usage() {
    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

[[ $# -ge 2 ]] || usage
DOMAIN="$1"
TARGET="$2"
HARNESS="${3:-all}"
T="${TARGET//\'/\'\'}" # SQL-quote the target

# hf [alias.] — harness predicate fragment; empty when harness=all
hf() { [[ "$HARNESS" == all ]] || printf "AND %sharness = '%s'" "${1:-}" "${HARNESS//\'/\'\'}"; }

ensure_db() {
    if [[ -z "${SESSIONS_DB:-}" ]]; then
        if [[ ! -f "$DB" || -z "$(find "$DB" -mmin -60 2>/dev/null)" ]]; then
            local ingest="$SCRIPT_DIR/../../session-analytics/scripts/ingest.py"
            if [[ -f "$ingest" ]]; then python3 "$ingest" >/dev/null 2>&1 || true; fi
        fi
    fi
    if [[ ! -f "$DB" ]]; then
        echo "No session database at $DB — no logs ingested yet. Insufficient signal."
        exit 0
    fi
    local n
    n="$(duckdb -init /dev/null "$DB" -noheader -list -c \
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'tool_uses'" 2>/dev/null || echo 0)"
    if [[ "$n" != 1 ]]; then
        echo "Session database at $DB has no ingested tables. Insufficient signal."
        exit 0
    fi
}

run() { duckdb -init /dev/null "$DB" -markdown -c "$1" 2>/dev/null || echo "(query failed)"; }

d_tool_usage() {
    echo "## Tool Usage: $TARGET  (harness=$HARNESS)"
    echo
    echo "### Frequency (top 20 tools, all)"
    run "SELECT tool_name, count(*) AS uses,
                round(count(*) * 100.0 / sum(count(*)) OVER (), 1) AS pct_of_all
         FROM tool_uses WHERE 1=1 $(hf)
         GROUP BY tool_name ORDER BY uses DESC LIMIT 20;"
    echo
    echo "### Weekly trend for the target"
    run "SELECT date_trunc('week', timestamp::DATE) AS week, count(*) AS uses
         FROM tool_uses WHERE tool_name = '$T' $(hf)
         GROUP BY week ORDER BY week;"
    echo
    echo "### Project distribution"
    run "SELECT regexp_extract(cwd, '.*/([^/]+)\$', 1) AS project, count(*) AS uses
         FROM tool_uses WHERE tool_name = '$T' $(hf)
         GROUP BY project ORDER BY uses DESC LIMIT 10;"
    if [[ "$TARGET" == Bash ]]; then
        echo
        echo "### Task fit: top Bash command prefixes"
        run "SELECT split_part(bash_cmd, ' ', 1) AS cmd_prefix, count(*) AS uses
             FROM tool_uses WHERE tool_name = 'Bash' AND bash_cmd IS NOT NULL $(hf)
             GROUP BY cmd_prefix ORDER BY uses DESC LIMIT 20;"
    fi
}

d_error_forensics() {
    echo "## Error Forensics: $TARGET  (harness=$HARNESS)"
    echo
    echo "### Error rate: target vs baseline"
    run "WITH target AS (
             SELECT count(*) AS total,
                    sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE tu.tool_name LIKE '$T' $(hf tu.)
         ),
         baseline AS (
             SELECT count(*) AS total,
                    sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE 1=1 $(hf tu.)
         )
         SELECT 'target' AS scope, total, errors,
                round(errors*100.0/nullif(total,0),1) AS error_pct FROM target
         UNION ALL
         SELECT 'baseline', total, errors,
                round(errors*100.0/nullif(total,0),1) FROM baseline;"
    echo
    echo "### Recurring error signatures"
    run "SELECT substr(tr.content, 1, 150) AS error, count(*) AS occ
         FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
         WHERE tu.tool_name LIKE '$T' AND tr.is_error = 'true' $(hf tu.)
         GROUP BY error ORDER BY occ DESC LIMIT 15;"
    if [[ "$TARGET" == "%" ]]; then
        echo
        echo "### Error rate by tool (>=5 calls)"
        run "SELECT tu.tool_name, count(*) AS total,
                    sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
                    round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
             FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
             WHERE 1=1 $(hf tu.)
             GROUP BY tu.tool_name HAVING count(*) >= 5
             ORDER BY errors DESC LIMIT 20;"
    fi
    echo
    echo "Note: <5 target calls = insufficient signal."
}

d_fix_recommendations() {
    echo "## Fix Recommendations (raw signal): $TARGET  (harness=$HARNESS)"
    echo
    echo "### High-error tools (>=40% errors, >=3 calls) — swap or fix call shape"
    run "SELECT tu.tool_name, count(*) AS calls,
                sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
                round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
         FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
         WHERE tu.tool_name LIKE '$T' $(hf tu.)
         GROUP BY tu.tool_name
         HAVING count(*) >= 3
            AND sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*) >= 40
         ORDER BY error_pct DESC, calls DESC LIMIT 15;"
    echo
    echo "### Allowlist adds (prefixes denied >=2 times; claude-dominant signal)"
    run "SELECT split_part(bash_cmd, ' ', 1) AS cmd_prefix, count(*) AS uses,
                sum(CASE WHEN tr.is_error='true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) AS denied
         FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
         WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL $(hf tu.)
         GROUP BY cmd_prefix
         HAVING sum(CASE WHEN tr.is_error='true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) >= 2
         ORDER BY denied DESC LIMIT 15;"
    echo
    echo "### Raw-bash that should route to a dedicated tool/skill"
    run "SELECT
             CASE
                 WHEN bash_cmd LIKE 'find %' OR bash_cmd LIKE '% find %' THEN 'find -> Glob / cheez-search'
                 WHEN bash_cmd LIKE 'grep %' OR bash_cmd LIKE 'egrep %' OR bash_cmd LIKE 'rg %' THEN 'grep/rg -> cheez-search'
                 WHEN bash_cmd LIKE 'cat %' AND bash_cmd NOT LIKE '%>%' THEN 'cat -> cheez-read'
                 WHEN bash_cmd LIKE 'sed %' OR bash_cmd LIKE '%sed -i%' THEN 'sed -> cheez-write / Edit'
                 WHEN bash_cmd LIKE '%python3%json%' THEN 'python3 json -> jq'
                 WHEN bash_cmd LIKE '%git add%' AND bash_cmd LIKE '%git commit%' THEN 'git add+commit -> /commit'
                 ELSE NULL
             END AS swap,
             count(*) AS uses
         FROM tool_uses tu
         WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL $(hf tu.)
         GROUP BY swap HAVING swap IS NOT NULL
         ORDER BY uses DESC;"
    echo
    echo "### MCP servers — repair (high error) or retire (idle)"
    run "SELECT split_part(mc.tool_name, '__', 2) AS server,
                count(*) AS calls,
                sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
                round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
         FROM mcp_calls mc JOIN tool_results tr ON mc.tool_use_id = tr.tool_use_id
         WHERE 1=1 $(hf mc.)
         GROUP BY server ORDER BY error_pct DESC, calls ASC LIMIT 20;"
    echo
    echo "Advisory only: sections with <2 rows = insufficient signal; empty denial data on codex/omp is missing signal, not zero friction."
}

d_permission_friction() {
    echo "## Permission Friction: $TARGET  (harness=$HARNESS; claude-dominant signal)"
    echo
    echo "### Denial categories"
    run "SELECT
             CASE
                 WHEN bash_cmd LIKE '%python3%' THEN 'python3 inline'
                 WHEN bash_cmd LIKE 'find %' OR bash_cmd LIKE '% find %' THEN 'find (use Glob)'
                 WHEN bash_cmd LIKE 'grep %' OR bash_cmd LIKE 'egrep %' THEN 'grep (use Grep)'
                 WHEN bash_cmd LIKE 'sed %' OR bash_cmd LIKE '%sed -i%' THEN 'sed (use Edit)'
                 WHEN bash_cmd LIKE 'cd %' AND bash_cmd LIKE '%git%' THEN 'cd+git (use wt-git)'
                 WHEN bash_cmd LIKE '%git add%&&%git commit%' THEN 'git add+commit (use /commit)'
                 ELSE 'other: ' || substr(bash_cmd, 1, 40)
             END AS category,
             count(*) AS denials
         FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
         WHERE tu.tool_name = 'Bash' AND tr.is_error = 'true'
           AND tr.content LIKE 'Permission to use Bash%' $(hf tu.)
         GROUP BY category ORDER BY denials DESC;"
    echo
    echo "### Allowlist gaps (>=5 uses, ordered by denials)"
    run "SELECT split_part(bash_cmd, ' ', 1) AS cmd_prefix, count(*) AS uses,
                sum(CASE WHEN tr.is_error='true' AND tr.content LIKE 'Permission%' THEN 1 ELSE 0 END) AS denied
         FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
         WHERE tu.tool_name = 'Bash' AND tu.bash_cmd IS NOT NULL $(hf tu.)
         GROUP BY cmd_prefix HAVING count(*) >= 5
         ORDER BY denied DESC LIMIT 20;"
    echo
    echo "### Compound-command friction (pipes / && that get denied)"
    run "SELECT substr(bash_cmd, 1, 120) AS cmd, count(*) AS denials
         FROM tool_uses tu JOIN tool_results tr ON tu.tool_use_id = tr.tool_use_id
         WHERE tu.tool_name = 'Bash' AND tr.is_error = 'true'
           AND tr.content LIKE 'Permission to use Bash%'
           AND (bash_cmd LIKE '%|%' OR bash_cmd LIKE '%&&%') $(hf tu.)
         GROUP BY cmd ORDER BY denials DESC LIMIT 15;"
    echo
    echo "Empty results on codex/omp = insufficient signal, not zero friction."
}

d_mcp_health() {
    echo "## MCP Health: $TARGET  (harness=$HARNESS; claude-dominant signal)"
    echo
    echo "### Volume & errors for the target server"
    run "SELECT split_part(mc.tool_name, '__', 2) AS server,
                count(*) AS calls,
                sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END) AS errors,
                round(sum(CASE WHEN tr.is_error='true' THEN 1 ELSE 0 END)*100.0/count(*),1) AS error_pct
         FROM mcp_calls mc
         LEFT JOIN tool_results tr ON mc.tool_use_id = tr.tool_use_id
         WHERE split_part(mc.tool_name, '__', 2) LIKE '$T' $(hf mc.)
         GROUP BY server ORDER BY calls DESC;"
    echo
    echo "### Method breakdown"
    run "SELECT split_part(mc.tool_name, '__', 3) AS method, count(*) AS calls
         FROM mcp_calls mc
         WHERE split_part(mc.tool_name, '__', 2) LIKE '$T' $(hf mc.)
         GROUP BY method ORDER BY calls DESC LIMIT 20;"
    echo
    echo "### Server leaderboard (idle detection)"
    run "SELECT split_part(tool_name, '__', 2) AS server,
                count(*) AS calls,
                count(DISTINCT sessionId) AS sessions,
                max(timestamp)::DATE AS last_used
         FROM mcp_calls WHERE 1=1 $(hf)
         GROUP BY server ORDER BY calls DESC;"
}

d_token_economics() {
    echo "## Token Economics: $TARGET  (harness=$HARNESS)"
    echo
    echo "### Signal probe: usage payloads per harness (0 with_usage = insufficient signal)"
    run "SELECT harness,
                count(*) FILTER (WHERE json_extract(message, '\$.usage') IS NOT NULL) AS with_usage,
                count(*) AS total
         FROM raw_entries WHERE message IS NOT NULL $(hf)
         GROUP BY harness;"
    echo
    echo "### Token totals per session (per assistant turn, NOT per tool call)"
    run "SELECT sessionId,
             sum(CAST(json_extract_string(message, '\$.usage.input_tokens') AS BIGINT)) AS input_tokens,
             sum(CAST(json_extract_string(message, '\$.usage.output_tokens') AS BIGINT)) AS output_tokens,
             sum(CAST(json_extract_string(message, '\$.usage.cache_read_input_tokens') AS BIGINT)) AS cache_read
         FROM raw_entries
         WHERE type = 'assistant' AND json_extract(message, '\$.usage') IS NOT NULL $(hf)
         GROUP BY sessionId ORDER BY output_tokens DESC LIMIT 10;"
    echo
    echo "### Call-volume proxy (labelled NOT cost)"
    run "SELECT tool_name, count(*) AS calls
         FROM tool_uses WHERE tool_name LIKE '$T' $(hf)
         GROUP BY tool_name ORDER BY calls DESC LIMIT 15;"
    echo
    echo "Token volume only — never estimate dollars."
}

ensure_db

case "$DOMAIN" in
    tool-usage)           d_tool_usage ;;
    error-forensics)      d_error_forensics ;;
    fix-recommendations)  d_fix_recommendations ;;
    permission-friction)  d_permission_friction ;;
    mcp-health)           d_mcp_health ;;
    token-economics)      d_token_economics ;;
    all)
        d_tool_usage; echo
        d_error_forensics; echo
        d_fix_recommendations; echo
        d_permission_friction; echo
        d_mcp_health; echo
        d_token_economics
        ;;
    *) echo "Unknown domain: $DOMAIN" >&2; usage ;;
esac
