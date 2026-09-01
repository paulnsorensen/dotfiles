#!/usr/bin/env bash
# analyze.sh <domain|all> <target> [harness] — prompt-analytics digests.
# Domains: prompt-analysis routing-accuracy knowledge-gaps
# Target: prompt-analysis / knowledge-gaps take a keyword ('%' = everything);
#         routing-accuracy takes a skill name (e.g. cheese).
# Harness: all (default) | claude | codex | omp | cursor | copilot
# SESSIONS_DB overrides the database path and disables auto-ingest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB="${SESSIONS_DB:-${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/session-analytics/sessions.duckdb}"
[[ "$DB" = /* ]] || DB="$PWD/$DB"

usage() {
    sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

[[ $# -ge 2 ]] || usage
DOMAIN="$1"
TARGET="$2"
HARNESS="${3:-all}"
T="${TARGET//\'/\'\'}"

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
        "SELECT count(*) FROM information_schema.tables WHERE table_name = 'raw_entries'" 2>/dev/null || echo 0)"
    if [[ "$n" != 1 ]]; then
        echo "Session database at $DB has no ingested tables. Insufficient signal."
        exit 0
    fi
}

run() { duckdb -init /dev/null "$DB" -markdown -c "$1" 2>/dev/null || echo "(query failed)"; }

# User text prompts: raw_entries rows whose message.content is a plain string.
PROMPT_WHERE="type = 'user' AND message IS NOT NULL
      AND json_type(json_extract(message, '\$.content')) = 'VARCHAR'"

d_prompt_analysis() {
    echo "## Prompt Analysis: $TARGET  (harness=$HARNESS)"
    echo
    echo "### Shape: slash-command vs freeform (matching the keyword)"
    run "WITH prompts AS (
             SELECT json_extract_string(message, '\$.content') AS txt
             FROM raw_entries WHERE $PROMPT_WHERE $(hf)
         )
         SELECT CASE WHEN txt LIKE '/%' THEN 'slash-command' ELSE 'freeform' END AS shape,
                count(*) AS n
         FROM prompts WHERE txt LIKE '%$T%' GROUP BY shape;"
    echo
    echo "### Top slash commands"
    run "SELECT lower(split_part(trim(json_extract_string(message, '\$.content')), ' ', 1)) AS cmd,
                count(*) AS uses
         FROM raw_entries
         WHERE $PROMPT_WHERE $(hf)
           AND trim(json_extract_string(message, '\$.content')) LIKE '/%'
         GROUP BY cmd ORDER BY uses DESC LIMIT 20;"
    echo
    echo "### Common session openers"
    run "WITH prompts AS (
             SELECT sessionId, timestamp,
                    json_extract_string(message, '\$.content') AS txt,
                    row_number() OVER (PARTITION BY sessionId ORDER BY timestamp) AS rn
             FROM raw_entries WHERE $PROMPT_WHERE $(hf)
         )
         SELECT substr(txt, 1, 80) AS opener, count(*) AS n
         FROM prompts WHERE rn = 1
         GROUP BY opener ORDER BY n DESC LIMIT 15;"
    echo
    echo "Low prompt volume = insufficient signal."
}

d_routing_accuracy() {
    echo "## Routing Accuracy: $TARGET  (harness=$HARNESS; correlational — no intent ground-truth)"
    echo
    echo "### Downstream skills within 5 min of $TARGET"
    run "WITH r AS (
             SELECT sessionId, timestamp::TIMESTAMP AS t0,
                    timestamp::TIMESTAMP + INTERVAL '5' MINUTE AS t1
             FROM skill_invocations WHERE skill_name = '$T' $(hf)
         )
         SELECT si.skill_name AS downstream, count(*) AS n
         FROM skill_invocations si JOIN r ON si.sessionId = r.sessionId
             AND si.timestamp::TIMESTAMP > r.t0 AND si.timestamp::TIMESTAMP <= r.t1
         WHERE si.skill_name <> '$T'
         GROUP BY downstream ORDER BY n DESC LIMIT 15;"
    echo
    echo "### Dead-ends (routings with no downstream skill)"
    run "WITH r AS (
             SELECT sessionId, timestamp, timestamp::TIMESTAMP AS t0,
                    timestamp::TIMESTAMP + INTERVAL '5' MINUTE AS t1
             FROM skill_invocations WHERE skill_name = '$T' $(hf)
         )
         SELECT count(*) AS routings_with_no_downstream
         FROM r WHERE NOT EXISTS (
             SELECT 1 FROM skill_invocations si
             WHERE si.sessionId = r.sessionId AND si.skill_name <> '$T'
               AND si.timestamp::TIMESTAMP > r.t0 AND si.timestamp::TIMESTAMP <= r.t1
         );"
    echo
    echo "### Immediate re-fires of $TARGET within 5 min"
    run "WITH r AS (
             SELECT sessionId, timestamp::TIMESTAMP AS t0,
                    timestamp::TIMESTAMP + INTERVAL '5' MINUTE AS t1
             FROM skill_invocations WHERE skill_name = '$T' $(hf)
         )
         SELECT count(*) AS immediate_refires
         FROM skill_invocations si JOIN r ON si.sessionId = r.sessionId
             AND si.timestamp::TIMESTAMP > r.t0 AND si.timestamp::TIMESTAMP <= r.t1
         WHERE si.skill_name = '$T';"
    echo
    echo "skill_invocations is claude-only; findings are <speculative> at most."
}

d_knowledge_gaps() {
    echo "## Knowledge Gaps: $TARGET  (harness=$HARNESS; medium signal — inference, not proof)"
    echo
    echo "### Topic recurrence in freeform prompts"
    run "WITH prompts AS (
             SELECT sessionId, json_extract_string(message, '\$.content') AS txt
             FROM raw_entries WHERE $PROMPT_WHERE $(hf)
         )
         SELECT count(*) AS mentions, count(DISTINCT sessionId) AS sessions
         FROM prompts
         WHERE txt NOT LIKE '/%' AND lower(txt) LIKE lower('%$T%');"
    echo
    echo "### Skills that fired in sessions mentioning the topic"
    run "WITH topic_sessions AS (
             SELECT DISTINCT sessionId
             FROM raw_entries
             WHERE $PROMPT_WHERE $(hf)
               AND lower(json_extract_string(message, '\$.content')) LIKE lower('%$T%')
         )
         SELECT si.skill_name, count(*) AS fired
         FROM skill_invocations si JOIN topic_sessions t ON si.sessionId = t.sessionId
         GROUP BY si.skill_name ORDER BY fired DESC LIMIT 15;"
    echo
    echo "### Repeated openers across sessions (>=3)"
    run "WITH openers AS (
             SELECT json_extract_string(message, '\$.content') AS txt,
                    row_number() OVER (PARTITION BY sessionId ORDER BY timestamp) AS rn
             FROM raw_entries WHERE $PROMPT_WHERE $(hf)
         )
         SELECT substr(lower(txt), 1, 50) AS opener_prefix, count(*) AS sessions
         FROM openers WHERE rn = 1 AND txt NOT LIKE '/%'
         GROUP BY opener_prefix HAVING count(*) >= 3
         ORDER BY sessions DESC LIMIT 15;"
    echo
    echo "Recurring topic + no skill fired = candidate gap only; <3 sessions = insufficient signal."
}

ensure_db

case "$DOMAIN" in
    prompt-analysis)   d_prompt_analysis ;;
    routing-accuracy)  d_routing_accuracy ;;
    knowledge-gaps)    d_knowledge_gaps ;;
    all)
        d_prompt_analysis; echo
        d_routing_accuracy; echo
        d_knowledge_gaps
        ;;
    *) echo "Unknown domain: $DOMAIN" >&2; usage ;;
esac
