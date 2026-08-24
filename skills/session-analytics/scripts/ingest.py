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
import subprocess
import sys
import time
from datetime import datetime, timedelta

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


def _codex_command(name, parsed, raw_input):
    """The executed command string for codex shell-ish tools, or None.

    Mirrors claude's ``input.command`` so ``tool_uses.bash_cmd`` populates:
    ``exec_command`` carries it in ``cmd``; legacy ``shell`` carries an argv
    array (the ``-lc``/``-c`` payload is the real command); the ``exec``
    custom tool's argument IS the raw code string.
    """
    if name == "exec_command" and isinstance(parsed, dict):
        cmd = parsed.get("cmd")
        return cmd if isinstance(cmd, str) else None
    if name == "shell" and isinstance(parsed, dict):
        cmd = parsed.get("command")
        if isinstance(cmd, str):
            return cmd
        if isinstance(cmd, list) and cmd:
            if len(cmd) == 3 and cmd[1] in ("-lc", "-c"):
                return str(cmd[2])
            return " ".join(str(c) for c in cmd)
        return None
    if name == "exec" and isinstance(raw_input, str):
        return raw_input
    return None


def codex_normalize(path):
    """Codex rollout JSONL -> canonical envelope.

    session_meta carries id + cwd; a response_item/function_call becomes an
    assistant tool_use block; a function_call_output OR custom_tool_call_output
    becomes a user tool_result block (dropping the custom outputs was the ~50%
    result-join gap — issue #704). Codex tool names (shell / apply_patch /
    custom tools) are kept verbatim, and ``input.command`` is normalized to the
    executed command string for shell-ish tools so ``bash_cmd`` extracts.
    ``tool_search_output`` items have no matching call item and are dropped.
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
                parsed = (
                    json.loads(raw_input) if isinstance(raw_input, str) else raw_input
                )
            except (json.JSONDecodeError, TypeError):
                parsed = {"raw": raw_input}
            if not isinstance(parsed, dict):
                parsed = {"raw": parsed}
            name = payload.get("name")
            command = _codex_command(name, parsed, raw_input)
            if command is not None:
                parsed["command"] = command
            yield {
                "harness": "codex",
                "type": "assistant",
                "timestamp": ts,
                "sessionId": session_id,
                "cwd": cwd,
                "message": {
                    "content": [
                        {
                            "type": "tool_use",
                            "id": payload.get("call_id"),
                            "name": name,
                            "input": parsed,
                        }
                    ]
                },
            }
        elif ptype in ("function_call_output", "custom_tool_call_output"):
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
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": payload.get("call_id"),
                            "content": out,
                            "is_error": is_error,
                        }
                    ]
                },
            }


def omp_discover():
    root = os.path.expanduser("~/.omp/agent/sessions")
    if not os.path.isdir(root):
        return []
    out = []
    for dirpath, _dirs, files in os.walk(root):
        out.extend(os.path.join(dirpath, f) for f in files if f.endswith(".jsonl"))
    return out


def omp_normalize(path):
    """oh-my-pi session JSONL -> canonical envelope.

    The ``session`` header entry carries id + cwd, threaded onto every row.
    ``message`` entries: assistant ``toolCall`` blocks become tool_use blocks
    (other blocks pass through); role ``toolResult`` becomes a user tool_result
    block joined on ``toolCallId``, with the msg-level ``isError`` boolean as
    the error flag; role ``user`` passes through. Tool names (``bash``, ``read``,
    ``mcp__<server>_<tool>``) are kept verbatim.
    """
    session_id = None
    cwd = None
    for entry in _iter_jsonl(path):
        if not isinstance(entry, dict):
            continue
        etype = entry.get("type")
        if etype == "session":
            session_id = entry.get("id") or session_id
            cwd = entry.get("cwd") or cwd
            continue
        if etype != "message":
            continue
        msg = entry.get("message")
        if not isinstance(msg, dict):
            continue
        ts = entry.get("timestamp")
        role = msg.get("role")
        if role == "assistant":
            blocks = []
            for block in msg.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "toolCall":
                    args = block.get("arguments")
                    if isinstance(args, str):
                        try:
                            args = json.loads(args)
                        except json.JSONDecodeError:
                            args = {"raw": args}
                    if not isinstance(args, dict):
                        args = {"raw": args}
                    blocks.append(
                        {
                            "type": "tool_use",
                            "id": block.get("id"),
                            "name": block.get("name"),
                            "input": args,
                        }
                    )
                else:
                    blocks.append(block)
            yield {
                "harness": "omp",
                "type": "assistant",
                "timestamp": ts,
                "sessionId": session_id,
                "cwd": cwd,
                "message": {"content": blocks},
            }
        elif role == "toolResult":
            text = "\n".join(
                b.get("text", "")
                for b in msg.get("content") or []
                if isinstance(b, dict) and b.get("type") == "text"
            )
            yield {
                "harness": "omp",
                "type": "user",
                "timestamp": ts,
                "sessionId": session_id,
                "cwd": cwd,
                "message": {
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": msg.get("toolCallId"),
                            "content": text,
                            "is_error": "true" if msg.get("isError") else "false",
                        }
                    ]
                },
            }
        elif role == "user":
            yield {
                "harness": "omp",
                "type": "user",
                "timestamp": ts,
                "sessionId": session_id,
                "cwd": cwd,
                "message": {"content": msg.get("content")},
            }


def cursor_discover():
    root = os.path.expanduser("~/.cursor/projects")
    if not os.path.isdir(root):
        return []
    out = []
    for dirpath, _dirs, files in os.walk(root):
        if "agent-transcripts" not in dirpath.split(os.sep):
            continue
        out.extend(os.path.join(dirpath, f) for f in files if f.endswith(".jsonl"))
    return out


_CURSOR_TIMESTAMP_RE = re.compile(
    r"<timestamp>\w+, (\w+ \d+, \d+, \d+:\d+ [AP]M) \(UTC([+-]\d+)\)</timestamp>"
)


def _cursor_parse_timestamp(text):
    """Parse a <timestamp>Weekday, Mon D, YYYY, H:MM AM (UTC±N)</timestamp> tag to ISO-8601 UTC."""
    m = _CURSOR_TIMESTAMP_RE.search(text)
    if not m:
        return None
    dt_str, offset = m.groups()
    try:
        # Naive parse is intentional: the UTC offset is applied manually on
        # the next line, so a %z-aware parse would double-count it.
        dt = datetime.strptime(dt_str, "%b %d, %Y, %I:%M %p")  # noqa: DTZ007
    except ValueError:
        return None
    dt -= timedelta(hours=int(offset))
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _cursor_session_id(path):
    return os.path.splitext(os.path.basename(path))[0]


def _cursor_resolve_slug(slug, fs_root="/"):
    """Decode a dash-encoded absolute path, preferring the longest existing dir.

    Cursor project slugs replace path separators with dashes
    (``Users-paul-Dev-easy-cheese``). A directory whose own name contains a
    dash is ambiguous if every dash is treated as a separator. Walk
    left-to-right and at each step take the longest prefix of remaining
    segments that exists under ``fs_root``; fall back to a naive split for
    any unresolved tail.
    """
    parts = [p for p in slug.split("-") if p]
    if not parts:
        return "/"
    prefix = fs_root.rstrip("/")
    i = 0
    while i < len(parts):
        matched = None
        next_i = None
        for j in range(len(parts), i, -1):
            candidate = "-".join(parts[i:j])
            trial = f"{prefix}/{candidate}" if prefix else f"/{candidate}"
            if os.path.isdir(trial):
                matched = trial
                next_i = j
                break
        if matched is None:
            rest = "/".join(parts[i:])
            return f"{prefix}/{rest}" if prefix else f"/{rest}"
        prefix = matched
        i = next_i
    return prefix or "/"


def _cursor_project_cwd(path):
    """Decode the project-slug directory into a cwd via filesystem resolve."""
    root = os.path.expanduser("~/.cursor/projects")
    rel = os.path.relpath(path, root)
    slug = rel.split(os.sep, 1)[0]
    return _cursor_resolve_slug(slug)


def _cursor_lineage(path):
    """Return (is_sidechain, parent_uuid) from an agent-transcripts path."""
    parts = os.path.normpath(path).split(os.sep)
    try:
        i = parts.index("agent-transcripts")
    except ValueError:
        return False, None
    if i + 3 < len(parts) and parts[i + 2] == "subagents":
        return True, parts[i + 1]
    return False, None


def _cursor_remap_mcp(name, tool_input):
    if name != "CallMcpTool":
        return name
    server = tool_input.get("server")
    tool_name = tool_input.get("toolName")
    if isinstance(server, str) and server and isinstance(tool_name, str) and tool_name:
        return f"mcp__{server}__{tool_name}"
    return name


def _cursor_stop_reason(entry):
    status = entry.get("status")
    err = entry.get("error")
    if status == "error" and isinstance(err, str) and "abort" in err.lower():
        return "aborted"
    return status


def cursor_normalize(path):
    """Cursor agent-transcript JSONL -> canonical envelope.

    One file per transcript (session id = the uuid filename); subagent
    transcripts live in a sibling ``subagents/`` dir with their own uuid/file.
    ``cwd`` is decoded from the project-slug directory name (longest existing
    path wins). Subagent files set ``isSidechain`` + ``parentUuid``. There are
    no per-call timestamps or tool_result blocks: the most recent <timestamp>
    seen in a user turn is carried forward onto later tool_use rows, and
    tool_use ids are synthesized (``session:line:block``) since results can
    never be joined. ``CallMcpTool`` calls with both ``server`` and
    ``toolName`` are remapped to ``mcp__<server>__<toolName>`` so they land
    in ``mcp_calls``; incomplete wrappers keep the native name.
    """
    session_id = _cursor_session_id(path)
    cwd = _cursor_project_cwd(path)
    is_sidechain, parent_uuid = _cursor_lineage(path)
    timestamp = None
    for line_no, entry in enumerate(_iter_jsonl(path)):
        if not isinstance(entry, dict):
            continue
        if entry.get("type") == "turn_ended":
            yield {
                "harness": "cursor",
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": session_id,
                "cwd": cwd,
                "isSidechain": is_sidechain,
                "parentUuid": parent_uuid,
                "message": {"stop_reason": _cursor_stop_reason(entry)},
            }
            continue
        role = entry.get("role")
        msg = entry.get("message")
        if not isinstance(msg, dict):
            continue
        blocks = msg.get("content")
        if not isinstance(blocks, list):
            continue
        if role == "user":
            for block in blocks:
                if isinstance(block, dict) and block.get("type") == "text":
                    ts = _cursor_parse_timestamp(block.get("text") or "")
                    if ts:
                        timestamp = ts
            continue
        if role != "assistant":
            continue
        out_blocks = []
        for block_idx, block in enumerate(blocks):
            if not isinstance(block, dict) or block.get("type") != "tool_use":
                continue
            name = block.get("name")
            tool_input = block.get("input")
            if not isinstance(tool_input, dict):
                tool_input = {}
            name = _cursor_remap_mcp(name, tool_input)
            out_blocks.append(
                {
                    "type": "tool_use",
                    "id": f"{session_id}:{line_no}:{block_idx}",
                    "name": name,
                    "input": tool_input,
                }
            )
        if out_blocks:
            yield {
                "harness": "cursor",
                "type": "assistant",
                "timestamp": timestamp,
                "sessionId": session_id,
                "cwd": cwd,
                "isSidechain": is_sidechain,
                "parentUuid": parent_uuid,
                "message": {"content": out_blocks},
            }


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
    ("omp", omp_discover, omp_normalize),
    ("cursor", cursor_discover, cursor_normalize),
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
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
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
        print(
            "No accessible sessions from any harness. Nothing to ingest.",
            file=sys.stderr,
        )
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
    run_sql(
        "SELECT harness, count(*) AS rows FROM raw_entries GROUP BY harness ORDER BY harness;"
    )

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
    # Claude omits is_error on most successful results (measured: ~99.5% of
    # absent-flag blocks carry non-error content), so an absent flag backfills
    # to explicit 'false' rather than a NULL every string compare treats as
    # success silently. is_error_explicit preserves whether the source block
    # carried the flag, so coverage stays measurable (issue #704).
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
            coalesce(json_extract_string(block, '$.is_error'), 'false') AS is_error,
            json_extract_string(block, '$.is_error') IS NOT NULL AS is_error_explicit,
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
              IN ('end_turn', 'stop_sequence', 'max_tokens', 'success', 'error', 'aborted');
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
        WHERE tool_name IN ('Agent', 'Task');
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

    run_sql(
        """
        SELECT
            (SELECT count(*) FROM tool_uses) AS tool_uses,
            (SELECT count(*) FROM tool_results) AS tool_results,
            (SELECT count(DISTINCT harness) FROM tool_uses) AS harnesses,
            (SELECT count(*) FROM agent_spawns) AS agent_spawns,
            (SELECT count(*) FROM skill_invocations) AS skill_invocations,
            (SELECT count(*) FROM mcp_calls) AS mcp_calls,
            (SELECT count(*) FROM sessions) AS sessions,
            (SELECT count(*) FROM permission_denials) AS permission_denials;
    """,
        db_path=DB_PATH,
    )

    # Coverage stanza (issue #704): measurement quality per harness, so
    # consumers can see how much of the call volume has joined results and how
    # many error flags were explicit in the source vs backfilled. A low
    # joined_pct means per-tool error rates for that harness are floors.
    print("\nCoverage (per harness):")
    run_sql(
        """
        WITH result_ids AS (SELECT DISTINCT tool_use_id FROM tool_results)
        SELECT
            u.harness,
            count(*) AS tool_uses,
            round(100.0 * avg(CASE WHEN r.tool_use_id IS NOT NULL THEN 1 ELSE 0 END), 1)
                AS results_joined_pct,
            (SELECT count(*) FROM tool_results tr WHERE tr.harness = u.harness)
                AS tool_results,
            (SELECT round(100.0 * avg(CASE WHEN tr.is_error_explicit THEN 1 ELSE 0 END), 1)
               FROM tool_results tr WHERE tr.harness = u.harness)
                AS explicit_error_flag_pct
        FROM tool_uses u
        LEFT JOIN result_ids r ON u.tool_use_id = r.tool_use_id
        GROUP BY u.harness
        ORDER BY u.harness;
    """,
        db_path=DB_PATH,
    )


if __name__ == "__main__":
    main()
