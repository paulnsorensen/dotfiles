#!/usr/bin/env bash
# Shared cohort and UTC window for every tool-efficiency query.
cohort_init() {
    SESSIONS_COHORT="${SESSIONS_COHORT:-retained}"
    case "$SESSIONS_COHORT" in
        retained|benchmark|all) ;;
        *) echo "Invalid SESSIONS_COHORT: $SESSIONS_COHORT" >&2; return 2 ;;
    esac
    SESSIONS_SINCE="${SESSIONS_SINCE:-0001-01-01T00:00:00Z}"
    SESSIONS_UNTIL="${SESSIONS_UNTIL:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local bound
    for bound in "$SESSIONS_SINCE" "$SESSIONS_UNTIL"; do
        if [[ ! "$bound" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
            echo "Invalid UTC window bound: $bound" >&2
            return 2
        fi
    done
    local since="${SESSIONS_SINCE//\'/\'\'}" until="${SESSIONS_UNTIL//\'/\'\'}"
    local validity
    validity="$(sessions_package sql -- "SELECT try_strptime('$since','%Y-%m-%dT%H:%M:%SZ') IS NOT NULL AND try_strptime('$until','%Y-%m-%dT%H:%M:%SZ') IS NOT NULL AND try_strptime('$since','%Y-%m-%dT%H:%M:%SZ') < try_strptime('$until','%Y-%m-%dT%H:%M:%SZ') AS valid")" || return $?
    if ! printf '%s\n' "$validity" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)[0]["valid"] else 1)'; then
        echo "Invalid UTC window: [$SESSIONS_SINCE, $SESSIONS_UNTIL)" >&2
        return 2
    fi
    COHORT_SQL="WITH classified AS (
        SELECT s.harness, s.sessionId,
            bool_or(regexp_matches(coalesce(s.project, ''), '(^|/)(benchmark|benchmarks|evals)(/|$)|(^|/)(skillz-preflight-|eval-)[^/]*($|/)')) OR
            coalesce(bool_or(r.artifact_marker), false) AS benchmark_marker
        FROM main.sessions s
        LEFT JOIN (
            SELECT harness, sessionId,
                bool_or(regexp_matches(coalesce(filename, '') || ' ' || coalesce(message::VARCHAR, ''), '(^|/)benchmark/results(/|$)')) AS artifact_marker
            FROM main.raw_entries GROUP BY harness, sessionId
        ) r ON s.harness = r.harness AND s.sessionId = r.sessionId
        GROUP BY s.harness, s.sessionId
    ),
    window_sessions AS (
        SELECT DISTINCT harness, sessionId FROM main.raw_entries
        WHERE try_cast(timestamp AS TIMESTAMPTZ) >= try_cast('$since' AS TIMESTAMPTZ)
          AND try_cast(timestamp AS TIMESTAMPTZ) < try_cast('$until' AS TIMESTAMPTZ)
          $(hf)
    ),
    scoped_sessions AS (
        SELECT c.harness, c.sessionId FROM classified c
        JOIN window_sessions w USING (harness, sessionId)
        WHERE '$SESSIONS_COHORT' = 'all'
           OR ('$SESSIONS_COHORT' = 'benchmark' AND c.benchmark_marker)
           OR ('$SESSIONS_COHORT' = 'retained' AND NOT c.benchmark_marker)
    ),
    tool_uses AS (
        SELECT tu.* FROM main.tool_uses tu JOIN scoped_sessions s USING (harness, sessionId)
        WHERE try_cast(tu.timestamp AS TIMESTAMPTZ) >= try_cast('$since' AS TIMESTAMPTZ)
          AND try_cast(tu.timestamp AS TIMESTAMPTZ) < try_cast('$until' AS TIMESTAMPTZ)
    ),
    tool_results AS (
        SELECT tr.harness, tr.sessionId, tr.tool_use_id,
            CASE WHEN bool_or(tr.is_error = 'true') THEN 'true' ELSE 'false' END AS is_error,
            coalesce(min(tr.content) FILTER (WHERE tr.is_error = 'true'), min(tr.content)) AS content
        FROM main.tool_results tr JOIN scoped_sessions s USING (harness, sessionId)
        WHERE try_cast(tr.timestamp AS TIMESTAMPTZ) >= try_cast('$since' AS TIMESTAMPTZ)
          AND try_cast(tr.timestamp AS TIMESTAMPTZ) < try_cast('$until' AS TIMESTAMPTZ)
        GROUP BY tr.harness, tr.sessionId, tr.tool_use_id
    ),
    mcp_calls AS (
        SELECT mc.* FROM main.mcp_calls mc JOIN scoped_sessions s USING (harness, sessionId)
        WHERE try_cast(mc.timestamp AS TIMESTAMPTZ) >= try_cast('$since' AS TIMESTAMPTZ)
          AND try_cast(mc.timestamp AS TIMESTAMPTZ) < try_cast('$until' AS TIMESTAMPTZ)
    ),
    raw_entries AS (
        SELECT re.* FROM main.raw_entries re JOIN scoped_sessions s USING (harness, sessionId)
        WHERE try_cast(re.timestamp AS TIMESTAMPTZ) >= try_cast('$since' AS TIMESTAMPTZ)
          AND try_cast(re.timestamp AS TIMESTAMPTZ) < try_cast('$until' AS TIMESTAMPTZ)
    )"
}
cohort_query() {
    local sql="$1"
    if [[ "$sql" == WITH\ * ]]; then
        sql="${sql#WITH }"
    fi
    sessions_package_sql_markdown "$COHORT_SQL, $sql"
}
cohort_audit() {
    echo "### Cohort audit (harness=$HARNESS; UTC [$SESSIONS_SINCE, $SESSIONS_UNTIL); selected=$SESSIONS_COHORT)"
    cohort_query "SELECT label AS cohort,
        (SELECT count(*) FROM classified c JOIN window_sessions w USING (harness, sessionId)
         WHERE label = 'all' OR (label = 'benchmark' AND c.benchmark_marker) OR (label = 'retained' AND NOT c.benchmark_marker)) AS sessions,
        (SELECT count(*) FROM main.tool_uses tu JOIN classified c USING (harness, sessionId)
         JOIN window_sessions w USING (harness, sessionId)
         WHERE try_cast(tu.timestamp AS TIMESTAMPTZ) >= try_cast('$SESSIONS_SINCE' AS TIMESTAMPTZ)
           AND try_cast(tu.timestamp AS TIMESTAMPTZ) < try_cast('$SESSIONS_UNTIL' AS TIMESTAMPTZ)
           AND (label = 'all' OR (label = 'benchmark' AND c.benchmark_marker) OR (label = 'retained' AND NOT c.benchmark_marker))) AS tool_calls
        FROM (VALUES ('all'), ('retained'), ('benchmark')) v(label)"
    echo "Path markers are heuristic, not verified provenance. Retained includes unknown provenance; no raw entries are deleted."
    echo
}
