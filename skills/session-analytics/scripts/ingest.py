#!/usr/bin/env python3
"""Ingest multi-harness coding-agent session logs into one DuckDB database.

Each harness has a *normalizing adapter* that discovers its native session
logs and emits one canonical row shape — the same JSON envelope Claude already
uses (type / message.content[] / timestamp / sessionId / cwd / …) plus a
``harness`` tag. The adapters write their canonical rows to a staging dir; the
flattening SQL then loads the union and threads ``harness`` through every
session-scoped table, so a single query can compare sources.

Adapters are discovery-gated and best-effort: a harness with no accessible logs
records a "no accessible logs" finding (see references/harness-coverage.md) and
is skipped non-fatally. "Done" is full coverage of what is reachable, not
parsing the unparseable.

Engine: DuckDB CLI — no Python duckdb module required. Skips ingestion if the
database is less than 1 hour old.

Usage: python3 ingest.py [--force]
"""

import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time

DB_DIR = os.path.expanduser("~/.claude/analytics")
DB_PATH = os.path.join(DB_DIR, "sessions.duckdb")
DB_TMP_PATH = os.path.join(DB_DIR, "sessions.duckdb.tmp")
STAGE_DIR = os.path.join(DB_DIR, "stage")
TTL_SECONDS = 3600  # 1 hour

# Canonical raw-entry columns the flattening SQL reads. Adapters emit a subset;
# read_json(union_by_name) fills the rest with NULL.
RAW_COLUMNS = {
    "harness": "VARCHAR",
    "type": "VARCHAR",
    "subtype": "VARCHAR",
    "timestamp": "VARCHAR",
    "sessionId": "VARCHAR",
    "uuid": "VARCHAR",
    "parentUuid": "VARCHAR",
    "message": "JSON",
    "version": "VARCHAR",
    "gitBranch": "VARCHAR",
    "slug": "VARCHAR",
    "cwd": "VARCHAR",
    "hookCount": "INTEGER",
    "hookInfos": "JSON",
    "hookErrors": "JSON",
    "preventedContinuation": "BOOLEAN",
    "stopReason": "VARCHAR",
    "hasOutput": "BOOLEAN",
    "level": "VARCHAR",
    "isSidechain": "BOOLEAN",
    "userType": "VARCHAR",
    "filename": "VARCHAR",
}


# --------------------------------------------------------------------------
# Harness adapters
#
# Each adapter is (name, discover, normalize):
#   discover()      -> list of source paths, or [] when no logs are reachable.
#   normalize(path) -> yields canonical raw-entry dicts (already harness-tagged).
# An adapter that finds nothing is non-fatal — the run logs it and continues.
# --------------------------------------------------------------------------


def _iter_jsonl(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def claude_discover():
    root = os.path.expanduser("~/.claude/projects")
    if not os.path.isdir(root):
        return []
    out = []
    for dirpath, _dirs, files in os.walk(root):
        out.extend(os.path.join(dirpath, f) for f in files if f.endswith(".jsonl"))
    return out


def claude_normalize(path):
    """Claude logs are already in the canonical envelope; just tag them."""
    for entry in _iter_jsonl(path):
        if not isinstance(entry, dict):
            continue
        entry["harness"] = "claude"
        yield entry


def codex_discover():
    root = os.path.expanduser("~/.codex/sessions")
    if not os.path.isdir(root):
        return []
    out = []
    for dirpath, _dirs, files in os.walk(root):
        out.extend(os.path.join(dirpath, f) for f in files if f.endswith(".jsonl"))
    return out


def _codex_output_is_error(out):
    """Detect failure in a codex ``function_call_output`` payload.

    Shell tool outputs embed a ``Process exited with code N`` line; a non-zero
    code is a failure. Dict payloads may carry an explicit status / exit_code.
    Returns the canonical "true"/"false" string, defaulting to "false" when no
    error signal is present (non-shell tools that emit no exit marker).
    """
    if isinstance(out, dict):
        status = out.get("status")
        if isinstance(status, str) and status.lower() in ("error", "failed", "failure"):
            return "true"
        code = out.get("exit_code")
        if isinstance(code, int) and code != 0:
            return "true"
        return "false"
    if isinstance(out, str):
        m = re.search(r"Process exited with code (\d+)", out)
        if m and m.group(1) != "0":
            return "true"
    return "false"


def codex_normalize(path):
    """Codex rollout JSONL -> canonical envelope.

    session_meta carries id + cwd; a response_item/function_call becomes an
    assistant tool_use block; a function_call_output becomes a user
    tool_result block. Codex tool names (shell / apply_patch / custom tools)
    are kept verbatim so harness comparison stays honest.
    """
    session_id = None
    cwd = None
    for entry in _iter_jsonl(path):
        if not isinstance(entry, dict):
            continue
        ts = entry.get("timestamp")
        payload = entry.get("payload")
        etype = entry.get("type")
        if etype == "session_meta" and isinstance(payload, dict):
            session_id = payload.get("id") or session_id
            cwd = payload.get("cwd") or cwd
            continue
        if etype == "turn_context" and isinstance(payload, dict):
            cwd = payload.get("cwd") or cwd
            continue
        if etype != "response_item" or not isinstance(payload, dict):
            continue
        ptype = payload.get("type")
        if ptype in ("function_call", "custom_tool_call"):
            raw_input = payload.get("arguments") or payload.get("input")
            try:
                parsed = json.loads(raw_input) if isinstance(raw_input, str) else raw_input
            except (json.JSONDecodeError, TypeError):
                parsed = {"raw": raw_input}
            if not isinstance(parsed, dict):
                parsed = {"raw": parsed}
            yield {
                "harness": "codex",
                "type": "assistant",
                "timestamp": ts,
                "sessionId": session_id,
                "cwd": cwd,
                "message": {
                    "content": [{
                        "type": "tool_use",
                        "id": payload.get("call_id"),
                        "name": payload.get("name"),
                        "input": parsed,
                    }]
                },
            }
        elif ptype == "function_call_output":
            out = payload.get("output")
            is_error = _codex_output_is_error(out)
            if isinstance(out, dict):
                out = json.dumps(out)
            yield {
                "harness": "codex",
                "type": "user",
                "timestamp": ts,
                "sessionId": session_id,
                "cwd": cwd,
                "message": {
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": payload.get("call_id"),
                        "content": out,
                        "is_error": is_error,
                    }]
                },
            }


def opencode_discover():
    db = os.path.expanduser("~/.local/share/opencode/opencode.db")
    return [db] if os.path.isfile(db) else []


def opencode_normalize(path):
    """opencode SQLite (part table, type='tool') -> canonical envelope.

    A tool part carries {tool, callID, state:{status,input,output}}. We emit
    an assistant tool_use and, for any terminal status (completed/error), a
    paired user tool_result. session.directory supplies cwd.
    """
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    except sqlite3.Error as exc:
        print(f"opencode: cannot open {path}: {exc}", file=sys.stderr)
        return
    try:
        rows = con.execute(
            """
            SELECT p.session_id, p.time_created, p.data, s.directory
            FROM part p
            LEFT JOIN session s ON s.id = p.session_id
            WHERE json_extract(p.data, '$.type') = 'tool'
            ORDER BY p.time_created
            """
        ).fetchall()
    except sqlite3.Error as exc:
        print(f"opencode: query failed on {path}: {exc}", file=sys.stderr)
        con.close()
        return
    con.close()
    for session_id, time_created, data, directory in rows:
        try:
            part = json.loads(data)
        except (json.JSONDecodeError, TypeError):
            continue
        ts = _ms_to_iso(time_created)
        call_id = part.get("callID") or part.get("id")
        state = part.get("state") or {}
        yield {
            "harness": "opencode",
            "type": "assistant",
            "timestamp": ts,
            "sessionId": session_id,
            "cwd": directory,
            "message": {
                "content": [{
                    "type": "tool_use",
                    "id": call_id,
                    "name": part.get("tool"),
                    "input": state.get("input") or {},
                }]
            },
        }
        if "output" in state or state.get("status") in ("completed", "error"):
            yield {
                "harness": "opencode",
                "type": "user",
                "timestamp": ts,
                "sessionId": session_id,
                "cwd": directory,
                "message": {
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": call_id,
                        "content": str(state.get("output", ""))[:500],
                        "is_error": "true" if state.get("status") == "error" else "false",
                    }]
                },
            }


def cursor_discover():
    # Cursor stores chat in an opaque state.vscdb SQLite blob whose schema is
    # undocumented and fragile across versions. No reliable adapter yet — see
    # references/harness-coverage.md. Discovery-gated best-effort: report and skip.
    return []


def copilot_discover():
    # GitHub Copilot CLI persists no local session transcript we can find
    # (~/.copilot holds skills/ + mcp-config.json only). See harness-coverage.md.
    return []


def _ms_to_iso(ms):
    if not ms:
        return None
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(ms) / 1000))
    except (ValueError, TypeError, OSError):
        return None


ADAPTERS = [
    ("claude", claude_discover, claude_normalize),
    ("codex", codex_discover, codex_normalize),
    ("opencode", opencode_discover, opencode_normalize),
    ("cursor", cursor_discover, None),
    ("copilot", copilot_discover, None),
]


# --------------------------------------------------------------------------
# Pipeline
# --------------------------------------------------------------------------


def db_is_fresh():
    if not os.path.exists(DB_PATH):
        return False
    age = time.time() - os.path.getmtime(DB_PATH)
    return age < TTL_SECONDS


def run_sql(sql, db_path=None):
    result = subprocess.run(
        ["duckdb", db_path or DB_TMP_PATH, "-c", sql],
        capture_output=True, text=True, timeout=600,
    )
    if result.returncode != 0:
        print(f"ERROR: {result.stderr[:500]}", file=sys.stderr)
        sys.exit(1)
    if result.stdout.strip():
        print(result.stdout.strip())


def stage_harnesses():
    """Run every adapter; write canonical rows to per-harness staging JSONL.

    Returns the list of harness names that produced at least one row. Adapters
    that discover no logs (or have no normalizer) are reported and skipped.
    """
    if os.path.isdir(STAGE_DIR):
        shutil.rmtree(STAGE_DIR)
    os.makedirs(STAGE_DIR, exist_ok=True)

    loaded = []
    for name, discover, normalize in ADAPTERS:
        sources = discover()
        if not sources or normalize is None:
            print(f"  {name}: no accessible logs — skipped")
            continue
        out_path = os.path.join(STAGE_DIR, f"{name}.jsonl")
        count = 0
        with open(out_path, "w", encoding="utf-8") as out:
            for src in sources:
                for entry in normalize(src):
                    out.write(json.dumps(entry) + "\n")
                    count += 1
        if count:
            loaded.append(name)
            print(f"  {name}: {count} canonical entries")
        else:
            os.remove(out_path)
            print(f"  {name}: no accessible logs — skipped")
    return loaded


def columns_struct():
    return "{" + ", ".join(f"{k}: '{v}'" for k, v in RAW_COLUMNS.items()) + "}"


def main():
    force = "--force" in sys.argv

    if db_is_fresh() and not force:
        age_min = (time.time() - os.path.getmtime(DB_PATH)) / 60
        print(f"Database is {age_min:.0f}m old (TTL=60m). Skipping ingestion.")
        print("Use --force to re-ingest.")
        return

    os.makedirs(DB_DIR, exist_ok=True)

    print("Discovering + normalizing harness sessions...")
    loaded = stage_harnesses()
    if not loaded:
        print("No accessible sessions from any harness. Nothing to ingest.", file=sys.stderr)
        sys.exit(1)

    if os.path.exists(DB_TMP_PATH):
        if os.path.isdir(DB_TMP_PATH):
            shutil.rmtree(DB_TMP_PATH)
        else:
            os.remove(DB_TMP_PATH)

    print("Loading canonical rows into DuckDB...")
    t0 = time.time()
    stage_glob = os.path.join(STAGE_DIR, "*.jsonl")

    # Step 1: union every harness's canonical JSONL into raw_entries.
    run_sql(f"""
        CREATE TABLE raw_entries AS
        SELECT *
        FROM read_json(
            '{stage_glob}',
            format='newline_delimited',
            union_by_name=true,
            ignore_errors=true,
            columns={columns_struct()}
        );
    """)
    run_sql("SELECT harness, count(*) AS rows FROM raw_entries GROUP BY harness ORDER BY harness;")

    # Step 2: tool_uses (flattened from assistant content blocks).
    print("  Creating tool_uses...")
    run_sql("""
        CREATE TABLE tool_uses AS
        WITH content_blocks AS (
            SELECT
                unnest(json_extract(json_extract(message, '$.content'), '$[*]')) AS block,
                harness, timestamp, sessionId, cwd, gitBranch
            FROM raw_entries
            WHERE type = 'assistant'
              AND message IS NOT NULL
              AND json_extract(message, '$.content') IS NOT NULL
              AND json_type(json_extract(message, '$.content')) = 'ARRAY'
        )
        SELECT
            harness,
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
            timestamp, sessionId, cwd, gitBranch
        FROM content_blocks
        WHERE json_extract_string(block, '$.type') = 'tool_use';
    """)

    # Step 3: tool_results (from user message content blocks).
    print("  Creating tool_results...")
    run_sql("""
        CREATE TABLE tool_results AS
        WITH content_blocks AS (
            SELECT
                unnest(json_extract(json_extract(message, '$.content'), '$[*]')) AS block,
                harness, timestamp, sessionId
            FROM raw_entries
            WHERE type = 'user'
              AND message IS NOT NULL
              AND json_type(json_extract(message, '$.content')) = 'ARRAY'
        )
        SELECT
            harness,
            json_extract_string(block, '$.tool_use_id') AS tool_use_id,
            substr(json_extract_string(block, '$.content'), 1, 500) AS content,
            json_extract_string(block, '$.is_error') AS is_error,
            timestamp, sessionId
        FROM content_blocks
        WHERE json_extract_string(block, '$.type') = 'tool_result';
    """)

    # Step 4: stop_events.
    print("  Creating stop_events...")
    run_sql("""
        CREATE TABLE stop_events AS
        SELECT
            harness,
            json_extract_string(message, '$.stop_reason') AS stop_reason,
            timestamp, sessionId, cwd, gitBranch
        FROM raw_entries
        WHERE type = 'assistant'
          AND message IS NOT NULL
          AND json_extract_string(message, '$.stop_reason')
              IN ('end_turn', 'stop_sequence', 'max_tokens');
    """)

    # Step 5: agent_spawns.
    print("  Creating agent_spawns...")
    run_sql("""
        CREATE TABLE agent_spawns AS
        SELECT
            harness,
            coalesce(agent_type, 'general-purpose') AS agent_type,
            agent_desc AS description,
            agent_mode AS mode,
            timestamp, sessionId, cwd
        FROM tool_uses
        WHERE tool_name = 'Agent';
    """)

    # Step 6: skill_invocations.
    print("  Creating skill_invocations...")
    run_sql("""
        CREATE TABLE skill_invocations AS
        SELECT
            harness, skill_name, skill_args AS args, timestamp, sessionId, cwd
        FROM tool_uses
        WHERE tool_name = 'Skill';
    """)

    # Step 7: mcp_calls.
    print("  Creating mcp_calls...")
    run_sql("""
        CREATE TABLE mcp_calls AS
        SELECT * FROM tool_uses WHERE tool_name LIKE 'mcp__%';
    """)

    # Step 8: sessions summary.
    print("  Creating sessions...")
    run_sql("""
        CREATE TABLE sessions AS
        SELECT
            harness, sessionId,
            min(timestamp) AS first_seen,
            max(timestamp) AS last_seen,
            cwd AS project,
            gitBranch AS branch,
            count(*) AS entry_count
        FROM raw_entries
        WHERE sessionId IS NOT NULL
          AND timestamp IS NOT NULL
        GROUP BY harness, sessionId, cwd, gitBranch;
    """)

    # Step 9: stop_hooks (claude-only fields, harness threaded through).
    print("  Creating stop_hooks...")
    run_sql("""
        CREATE TABLE stop_hooks AS
        SELECT
            harness, timestamp, sessionId, hookCount, hookInfos, hookErrors,
            preventedContinuation, stopReason, hasOutput, level
        FROM raw_entries
        WHERE type = 'system' AND subtype = 'stop_hook_summary';
    """)

    # Step 10: permission_denials.
    print("  Creating permission_denials...")
    run_sql("""
        CREATE TABLE permission_denials AS
        SELECT harness, content, sessionId, timestamp
        FROM tool_results
        WHERE content LIKE 'Permission to use % has been denied%'
           OR content LIKE 'Hook PreToolUse:% denied this tool%'
           OR content LIKE '%The user doesn''t want to proceed%';
    """)

    print("  Creating indexes...")
    run_sql("""
        CREATE INDEX idx_tool_uses_name ON tool_uses(tool_name);
        CREATE INDEX idx_tool_uses_session ON tool_uses(sessionId);
        CREATE INDEX idx_tool_uses_harness ON tool_uses(harness);
        CREATE INDEX idx_tool_results_error ON tool_results(is_error);
        CREATE INDEX idx_sessions_id ON sessions(sessionId);
    """)

    os.replace(DB_TMP_PATH, DB_PATH)

    elapsed = time.time() - t0
    print(f"\nIngestion complete in {elapsed:.1f}s")

    run_sql("""
        SELECT
            (SELECT count(*) FROM tool_uses) AS tool_uses,
            (SELECT count(*) FROM tool_results) AS tool_results,
            (SELECT count(DISTINCT harness) FROM tool_uses) AS harnesses,
            (SELECT count(*) FROM agent_spawns) AS agent_spawns,
            (SELECT count(*) FROM skill_invocations) AS skill_invocations,
            (SELECT count(*) FROM mcp_calls) AS mcp_calls,
            (SELECT count(*) FROM sessions) AS sessions,
            (SELECT count(*) FROM permission_denials) AS permission_denials;
    """, db_path=DB_PATH)


if __name__ == "__main__":
    main()
