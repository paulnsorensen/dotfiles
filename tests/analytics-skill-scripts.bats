#!/usr/bin/env bats
# Tests for the session-log analytics skill scripts (skills/*/scripts/).
# Fixtures are real DuckDB databases; SESSIONS_DB pins the path and disables
# the scripts' auto-ingest.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SKILLS="$DOTFILES_DIR/skills"

setup() {
    TMPROOT="$(mktemp -d)"
    TMPROOT="$(cd "$TMPROOT" && pwd -P)"
    export TMPROOT
    FIXTURE_DB="$TMPROOT/sessions.duckdb"
    export SESSIONS_DB="$FIXTURE_DB"
}

teardown() {
    rm -rf "$TMPROOT"
}

need_duckdb() {
    command -v duckdb >/dev/null 2>&1 || skip "duckdb not installed"
}

make_fixture() {
    need_duckdb
    duckdb -init /dev/null "$FIXTURE_DB" -c "
CREATE TABLE tool_uses (harness VARCHAR, tool_name VARCHAR, tool_use_id VARCHAR,
    bash_cmd VARCHAR, skill_name VARCHAR, agent_type VARCHAR, file_path VARCHAR,
    timestamp VARCHAR, sessionId VARCHAR, cwd VARCHAR);
CREATE TABLE tool_results (harness VARCHAR, tool_use_id VARCHAR, content VARCHAR,
    is_error VARCHAR, timestamp VARCHAR, sessionId VARCHAR);
CREATE TABLE sessions (harness VARCHAR, sessionId VARCHAR, first_seen VARCHAR,
    last_seen VARCHAR, project VARCHAR, branch VARCHAR, entry_count BIGINT);
CREATE TABLE skill_invocations (harness VARCHAR, skill_name VARCHAR, args VARCHAR,
    timestamp VARCHAR, sessionId VARCHAR, cwd VARCHAR);
CREATE TABLE mcp_calls (harness VARCHAR, tool_name VARCHAR, tool_use_id VARCHAR,
    timestamp VARCHAR, sessionId VARCHAR, cwd VARCHAR);
CREATE TABLE raw_entries (harness VARCHAR, type VARCHAR, message VARCHAR,
    timestamp VARCHAR, sessionId VARCHAR);
CREATE TABLE stop_hooks (harness VARCHAR, timestamp VARCHAR, sessionId VARCHAR,
    preventedContinuation VARCHAR, stopReason VARCHAR, level VARCHAR);

INSERT INTO tool_uses VALUES
    ('claude','Bash','tu1','git status',NULL,NULL,NULL,'2026-08-01T10:00:00Z','s1','/Users/t/proj'),
    ('claude','Read','tu2',NULL,NULL,NULL,'/Users/t/proj/main.rs','2026-08-01T10:01:00Z','s1','/Users/t/proj'),
    ('claude','Edit','tu3',NULL,NULL,NULL,'/Users/t/proj/main.rs','2026-08-01T10:02:00Z','s1','/Users/t/proj'),
    ('claude','Bash','tu4','cargo test',NULL,NULL,NULL,'2026-08-01T10:03:00Z','s1','/Users/t/proj'),
    ('claude','Bash','tu5','grep foo | sort',NULL,NULL,NULL,'2026-08-01T10:04:00Z','s1','/Users/t/proj');
INSERT INTO tool_results VALUES
    ('claude','tu1','ok','false','2026-08-01T10:00:01Z','s1'),
    ('claude','tu2','File not found: main.rs','true','2026-08-01T10:01:01Z','s1'),
    ('claude','tu3','ok','false','2026-08-01T10:02:01Z','s1'),
    ('claude','tu4','test result: ok','false','2026-08-01T10:03:01Z','s1'),
    ('claude','tu5','Permission to use Bash with command grep foo | sort has been denied','true','2026-08-01T10:04:01Z','s1'),
    ('claude','tu6','ok','false','2026-08-01T10:05:01Z','s1');
INSERT INTO sessions VALUES
    ('claude','s1','2026-08-01T10:00:00Z','2026-08-01T11:00:00Z','/Users/t/proj','main',42);
INSERT INTO skill_invocations VALUES
    ('claude','cheese',NULL,'2026-08-01T10:00:00Z','s1','/Users/t/proj'),
    ('claude','cook',NULL,'2026-08-01T10:02:00Z','s1','/Users/t/proj');
INSERT INTO mcp_calls VALUES
    ('claude','mcp__tilth__tilth_read','tu6','2026-08-01T10:05:00Z','s1','/Users/t/proj');
INSERT INTO raw_entries VALUES
    ('claude','user','{\"content\": \"fix the auth bug\"}','2026-08-01T10:00:00Z','s1'),
    ('claude','user','{\"content\": \"/cheese go\"}','2026-08-01T10:10:00Z','s1');
"
}

make_empty_db() {
    need_duckdb
    duckdb -init /dev/null "$FIXTURE_DB" -c "SELECT 1;" >/dev/null
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || {
        echo "expected to contain: $2" >&2
        echo "actual: $1" >&2
        return 1
    }
}

assert_not_contains() {
    [[ "$1" != *"$2"* ]] || {
        echo "expected NOT to contain: $2" >&2
        echo "actual: $1" >&2
        return 1
    }
}

# ── missing / empty database ────────────────────────────────────────

@test "query.sh reports a missing database gracefully" {
    run "$SKILLS/session-analytics/scripts/query.sh" tools
    [ "$status" -eq 0 ]
    assert_contains "$output" "No session database"
}

@test "tool-efficiency analyze.sh reports a missing database gracefully" {
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Bash
    [ "$status" -eq 0 ]
    assert_contains "$output" "No session database"
}

@test "recover.sh reports an empty database gracefully" {
    make_empty_db
    run "$SKILLS/work-recovery/scripts/recover.sh" s1
    [ "$status" -eq 0 ]
    assert_contains "$output" "no ingested tables"
}

# ── session-analytics/scripts/query.sh ──────────────────────────────

@test "query.sh tools reports per-tool counts" {
    make_fixture
    run "$SKILLS/session-analytics/scripts/query.sh" tools
    [ "$status" -eq 0 ]
    assert_contains "$output" "Bash"
    assert_contains "$output" "3"
}

@test "query.sh errors reports error rates" {
    make_fixture
    run "$SKILLS/session-analytics/scripts/query.sh" errors
    [ "$status" -eq 0 ]
    assert_contains "$output" "error_pct"
    assert_contains "$output" "Read"
    assert_contains "$output" "100.0"
}

@test "query.sh honors a harness filter" {
    make_fixture
    run "$SKILLS/session-analytics/scripts/query.sh" tools codex
    [ "$status" -eq 0 ]
    assert_not_contains "$output" "Bash"
}

@test "query.sh sql runs raw SQL" {
    make_fixture
    run "$SKILLS/session-analytics/scripts/query.sh" sql "SELECT count(*) AS n FROM tool_uses"
    [ "$status" -eq 0 ]
    assert_contains "$output" "5"
}

@test "query.sh rejects an unknown report" {
    make_fixture
    run "$SKILLS/session-analytics/scripts/query.sh" bogus
    [ "$status" -eq 2 ]
}

# ── tool-efficiency/scripts/analyze.sh ──────────────────────────────

@test "analyze.sh tool-usage Bash includes frequency and task fit" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" tool-usage Bash
    [ "$status" -eq 0 ]
    assert_contains "$output" "Frequency"
    assert_contains "$output" "Task fit"
    assert_contains "$output" "git"
}

@test "analyze.sh error-forensics reports target vs baseline and signatures" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" error-forensics Read
    [ "$status" -eq 0 ]
    assert_contains "$output" "baseline"
    assert_contains "$output" "File not found"
}

@test "analyze.sh permission-friction categorizes denials" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" permission-friction Bash
    [ "$status" -eq 0 ]
    assert_contains "$output" "grep (use Grep)"
    assert_contains "$output" "Compound-command"
    assert_contains "$output" 'grep foo \| sort'
}

@test "analyze.sh mcp-health lists servers" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" mcp-health %
    [ "$status" -eq 0 ]
    assert_contains "$output" "tilth"
    assert_contains "$output" "tilth_read"
}

@test "analyze.sh rejects an unknown domain" {
    make_fixture
    run "$SKILLS/tool-efficiency/scripts/analyze.sh" bogus Bash
    [ "$status" -eq 2 ]
}

# ── prompt-analytics/scripts/analyze.sh ─────────────────────────────

@test "prompt-analysis splits slash-command vs freeform" {
    make_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" prompt-analysis %
    [ "$status" -eq 0 ]
    assert_contains "$output" "freeform"
    assert_contains "$output" "/cheese"
}

@test "routing-accuracy finds the downstream skill" {
    make_fixture
    run "$SKILLS/prompt-analytics/scripts/analyze.sh" routing-accuracy cheese
    [ "$status" -eq 0 ]
    assert_contains "$output" "cook"
    assert_contains "$output" "no intent ground-truth"
}

# ── work-recovery scripts ───────────────────────────────────────────

@test "sessions.sh lists the recent session" {
    make_fixture
    run "$SKILLS/work-recovery/scripts/sessions.sh" proj
    [ "$status" -eq 0 ]
    assert_contains "$output" "s1"
    assert_contains "$output" "main"
}

@test "recover.sh reconstructs goal, files, and verified state" {
    make_fixture
    run "$SKILLS/work-recovery/scripts/recover.sh" s1
    [ "$status" -eq 0 ]
    assert_contains "$output" "fix the auth bug"
    assert_contains "$output" "main.rs"
    assert_contains "$output" "cargo test"
}

@test "recover.sh requires a sessionId" {
    run "$SKILLS/work-recovery/scripts/recover.sh"
    [ "$status" -eq 2 ]
}
