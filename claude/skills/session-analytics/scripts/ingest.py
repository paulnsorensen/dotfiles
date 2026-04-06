#!/usr/bin/env python3
"""Ingest Claude JSONL session logs into a persistent DuckDB database.

Materializes flattened views for fast querying. Uses DuckDB CLI — no Python
module required. Skips ingestion if the database is less than 1 hour old.

Usage: python3 ingest.py [--force]
"""

import subprocess
import sys
import os
import time

DB_DIR = os.path.expanduser("~/.claude/analytics")
DB_PATH = os.path.join(DB_DIR, "sessions.duckdb")
DB_TMP_PATH = os.path.join(DB_DIR, "sessions.duckdb.tmp")
JSONL_GLOB = os.path.expanduser("~/.claude/projects/**/*.jsonl")
TTL_SECONDS = 3600  # 1 hour


def db_is_fresh():
    if not os.path.exists(DB_PATH):
        return False
    age = time.time() - os.path.getmtime(DB_PATH)
    return age < TTL_SECONDS


def run_sql(sql, db_path=None):
    result = subprocess.run(
        ["duckdb", db_path or DB_TMP_PATH, "-c", sql],
        capture_output=True, text=True, timeout=600
    )
    if result.returncode != 0:
        print(f"ERROR: {result.stderr[:500]}", file=sys.stderr)
        sys.exit(1)
    if result.stdout.strip():
        print(result.stdout.strip())


def main():
    force = "--force" in sys.argv

    if db_is_fresh() and not force:
        age_min = (time.time() - os.path.getmtime(DB_PATH)) / 60
        print(f"Database is {age_min:.0f}m old (TTL=60m). Skipping ingestion.")
        print("Use --force to re-ingest.")
        return

    os.makedirs(DB_DIR, exist_ok=True)

    # Ingest into tmp file; atomically replace only on success
    if os.path.exists(DB_TMP_PATH):
        os.remove(DB_TMP_PATH)

    print("Ingesting JSONL logs into DuckDB...")
    t0 = time.time()

    # Step 1: Load raw entries into a persistent table
    run_sql(f"""
        CREATE TABLE raw_entries AS
        SELECT *
        FROM read_json(
            '{JSONL_GLOB}',
            format='newline_delimited',
            union_by_name=true,
            ignore_errors=true,
            columns={{
                type: 'VARCHAR',
                subtype: 'VARCHAR',
                timestamp: 'VARCHAR',
                sessionId: 'VARCHAR',
                uuid: 'VARCHAR',
                parentUuid: 'VARCHAR',
                message: 'JSON',
                version: 'VARCHAR',
                gitBranch: 'VARCHAR',
                slug: 'VARCHAR',
                cwd: 'VARCHAR',
                hookCount: 'INTEGER',
                hookInfos: 'JSON',
                hookErrors: 'JSON',
                preventedContinuation: 'BOOLEAN',
                stopReason: 'VARCHAR',
                hasOutput: 'BOOLEAN',
                level: 'VARCHAR',
                isSidechain: 'BOOLEAN',
                userType: 'VARCHAR',
                filename: 'VARCHAR'
            }}
        );
    """)

    run_sql("SELECT count(*) AS raw_entries_loaded FROM raw_entries;")

    # Step 2: Create tool_uses view (flattened from assistant content blocks)
    print("  Creating tool_uses...")
    run_sql("""
        CREATE TABLE tool_uses AS
        WITH content_blocks AS (
            SELECT
                unnest(json_extract(json_extract(message, '$.content'), '$[*]')) AS block,
                timestamp,
                sessionId,
                cwd,
                gitBranch
            FROM raw_entries
            WHERE type = 'assistant'
              AND message IS NOT NULL
              AND json_extract(message, '$.content') IS NOT NULL
              AND json_type(json_extract(message, '$.content')) = 'ARRAY'
        )
        SELECT
            json_extract_string(block, '$.name') AS tool_name,
            json_extract_string(block, '$.id') AS tool_use_id,
            json_extract(block, '$.input') AS input,
            json_extract_string(block, '$.input.command') AS bash_cmd,
            json_extract_string(block, '$.input.skill') AS skill_name,
            json_extract_string(block, '$.input.args') AS skill_args,
            json_extract_string(block, '$.input.subagent_type') AS agent_type,
            json_extract_string(block, '$.input.description') AS agent_desc,
            json_extract_string(block, '$.input.mode') AS agent_mode,
            json_extract_string(block, '$.input.pattern') AS grep_pattern,
            json_extract_string(block, '$.input.file_path') AS file_path,
            json_extract_string(block, '$.input.query') AS query,
            timestamp,
            sessionId,
            cwd,
            gitBranch
        FROM content_blocks
        WHERE json_extract_string(block, '$.type') = 'tool_use';
    """)

    # Step 3: Create tool_results view (from user message content blocks)
    print("  Creating tool_results...")
    run_sql("""
        CREATE TABLE tool_results AS
        WITH content_blocks AS (
            SELECT
                unnest(json_extract(json_extract(message, '$.content'), '$[*]')) AS block,
                timestamp,
                sessionId
            FROM raw_entries
            WHERE type = 'user'
              AND message IS NOT NULL
              AND json_type(json_extract(message, '$.content')) = 'ARRAY'
        )
        SELECT
            json_extract_string(block, '$.tool_use_id') AS tool_use_id,
            substr(json_extract_string(block, '$.content'), 1, 500) AS content,
            json_extract_string(block, '$.is_error') AS is_error,
            timestamp,
            sessionId
        FROM content_blocks
        WHERE json_extract_string(block, '$.type') = 'tool_result';
    """)

    # Step 4: Create stop_events view
    print("  Creating stop_events...")
    run_sql("""
        CREATE TABLE stop_events AS
        SELECT
            json_extract_string(message, '$.stop_reason') AS stop_reason,
            timestamp,
            sessionId,
            cwd,
            gitBranch
        FROM raw_entries
        WHERE type = 'assistant'
          AND message IS NOT NULL
          AND json_extract_string(message, '$.stop_reason')
              IN ('end_turn', 'stop_sequence', 'max_tokens');
    """)

    # Step 5: Create agent_spawns view
    print("  Creating agent_spawns...")
    run_sql("""
        CREATE TABLE agent_spawns AS
        SELECT
            coalesce(agent_type, 'general-purpose') AS agent_type,
            agent_desc AS description,
            agent_mode AS mode,
            timestamp,
            sessionId,
            cwd
        FROM tool_uses
        WHERE tool_name = 'Agent';
    """)

    # Step 6: Create skill_invocations view
    print("  Creating skill_invocations...")
    run_sql("""
        CREATE TABLE skill_invocations AS
        SELECT
            skill_name,
            skill_args AS args,
            timestamp,
            sessionId,
            cwd
        FROM tool_uses
        WHERE tool_name = 'Skill';
    """)

    # Step 7: Create mcp_calls view
    print("  Creating mcp_calls...")
    run_sql("""
        CREATE TABLE mcp_calls AS
        SELECT *
        FROM tool_uses
        WHERE tool_name LIKE 'mcp__%';
    """)

    # Step 8: Create sessions summary
    print("  Creating sessions...")
    run_sql("""
        CREATE TABLE sessions AS
        SELECT
            sessionId,
            min(timestamp) AS first_seen,
            max(timestamp) AS last_seen,
            cwd AS project,
            gitBranch AS branch,
            count(*) AS entry_count
        FROM raw_entries
        WHERE sessionId IS NOT NULL
          AND timestamp IS NOT NULL
        GROUP BY sessionId, cwd, gitBranch;
    """)

    # Step 9: Create stop_hooks view
    print("  Creating stop_hooks...")
    run_sql("""
        CREATE TABLE stop_hooks AS
        SELECT
            timestamp,
            sessionId,
            hookCount,
            hookInfos,
            hookErrors,
            preventedContinuation,
            stopReason,
            hasOutput,
            level
        FROM raw_entries
        WHERE type = 'system'
          AND subtype = 'stop_hook_summary';
    """)

    # Step 10: Create permission_denials view (common error pattern)
    print("  Creating permission_denials...")
    run_sql("""
        CREATE TABLE permission_denials AS
        SELECT
            content,
            sessionId,
            timestamp
        FROM tool_results
        WHERE content LIKE 'Permission to use % has been denied%'
           OR content LIKE 'Hook PreToolUse:% denied this tool%'
           OR content LIKE '%The user doesn''t want to proceed%';
    """)

    # Create indexes for common query patterns
    print("  Creating indexes...")
    run_sql("""
        CREATE INDEX idx_tool_uses_name ON tool_uses(tool_name);
        CREATE INDEX idx_tool_uses_session ON tool_uses(sessionId);
        CREATE INDEX idx_tool_results_error ON tool_results(is_error);
        CREATE INDEX idx_sessions_id ON sessions(sessionId);
    """)

    # Atomically replace the live database only after full success
    os.replace(DB_TMP_PATH, DB_PATH)

    elapsed = time.time() - t0
    print(f"\nIngestion complete in {elapsed:.1f}s")

    # Print summary against the now-live database
    run_sql("""
        SELECT
            (SELECT count(*) FROM tool_uses) AS tool_uses,
            (SELECT count(*) FROM tool_results) AS tool_results,
            (SELECT count(*) FROM stop_events) AS stop_events,
            (SELECT count(*) FROM agent_spawns) AS agent_spawns,
            (SELECT count(*) FROM skill_invocations) AS skill_invocations,
            (SELECT count(*) FROM mcp_calls) AS mcp_calls,
            (SELECT count(*) FROM sessions) AS sessions,
            (SELECT count(*) FROM permission_denials) AS permission_denials;
    """, db_path=DB_PATH)


if __name__ == "__main__":
    main()
