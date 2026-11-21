#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    export TEST_ROOT="$TEST_HOME/secret-client"
    export SOCKET="$TEST_ROOT/request.sock"
    export CONTROL="$TEST_ROOT/control.sock"
    export POLICY="$TEST_ROOT/policy.json"
    export CREDENTIAL="$TEST_ROOT/credential"
    export UPSTREAM="$TEST_ROOT/upstream.py"
    export CALLS="$TEST_ROOT/calls.jsonl"
    export PYTHON=/usr/bin/python3
    [[ -x "$PYTHON" ]] || skip "/usr/bin/python3 is required"
    mkdir -p "$TEST_ROOT"
    printf 'sentinel-credential-value' > "$CREDENTIAL"
    cat > "$UPSTREAM" <<'PY'
import json
import os
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "notifications/initialized":
        with open(sys.argv[1], "a", encoding="utf-8") as calls:
            calls.write(json.dumps({"method": method}) + "\n")
        continue
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {}}
    elif method == "tools/call":
        name = request["params"]["name"]
        args = request["params"]["arguments"]
        with open(sys.argv[1], "a", encoding="utf-8") as calls:
            calls.write(json.dumps({"method": method, "name": name, "arguments": args}) + "\n")
        query = args.get("query", "")
        if query == "sleep":
            time.sleep(2)
        if query == "disconnect":
            sys.exit(0)
        if query == "malformed":
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"]}), flush=True)
            continue
        if query == "rpc-error":
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32000, "message": "upstream failed"}}), flush=True)
            continue
        if query == "wrong-id":
            print(json.dumps({"jsonrpc": "2.0", "id": 999, "result": {}}), flush=True)
            continue
        result = {"content": [{"type": "text", "text": "answer:" + name}]}
        if query == "tool-error":
            result["isError"] = True
        if query == "structured":
            result["structuredContent"] = {"answer": name}
        if query == "escape":
            result["content"][0]["text"] = "safe\x1b[31mtext\nnext\tcolumn\x00\x9b"
        if query == "structured-only":
            result = {"structuredContent": {"text": "safe\x9bvalue\x1b[31m"}}
        if query == "credential":
            result["content"][0]["text"] = os.environ["FAKE_SECRET"]
    else:
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
PY
    chmod 700 "$UPSTREAM"
    cat > "$POLICY" <<EOF
{"consumer":"fixture","request_uid":$(id -u),"operator_uid":$(id -u),"upstream":{"argv":["$PYTHON","$UPSTREAM","$CALLS"],"credential_env":"FAKE_SECRET","credential_file":"$CREDENTIAL"},"tools":{"read":["tavily_search","tavily_extract","resolve-library-id","query-docs"],"write":[]}}
EOF
    chmod 600 "$POLICY" "$CREDENTIAL"
    "$REAL_DOTFILES_DIR/bin/agent-secret-broker" --policy "$POLICY" --socket "$SOCKET" --control-socket "$CONTROL" >"$TEST_ROOT/broker.log" 2>&1 &
    BROKER_PID=$!
    for _ in {1..250}; do
        [[ -S "$SOCKET" && -S "$CONTROL" ]] && return
        sleep 0.02
    done
    return 1
}

teardown() {
    if [[ -n "${PEER_PID:-}" ]]; then
        kill "$PEER_PID" 2>/dev/null || true
        wait "$PEER_PID" 2>/dev/null || true
    fi
    if [[ -n "${BROKER_PID:-}" ]]; then
        kill "$BROKER_PID" 2>/dev/null || true
        wait "$BROKER_PID" 2>/dev/null || true
    fi
    teardown_test_env
}

start_peer() {
    local mode="$1"
    export PEER_SOCKET="$TEST_ROOT/peer.sock"
    "$PYTHON" - "$PEER_SOCKET" "$mode" <<'PY' &
import json
import socket
import sys
import time

listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(sys.argv[1])
listener.listen(1)
connection, _ = listener.accept()
with connection:
    requests = connection.makefile("rb")
    initialize = json.loads(requests.readline())
    connection.sendall((json.dumps({"jsonrpc": "2.0", "id": initialize["id"], "result": {"protocolVersion": "2025-06-18"}}) + "\n").encode())
    requests.readline()
    requests.readline()
    if sys.argv[2] == "oversized":
        connection.sendall(b"x" * ((1 << 20) + 1) + b"\n")
    elif sys.argv[2] == "notifications":
        end = time.monotonic() + 2
        while time.monotonic() < end:
            try:
                connection.sendall(b'{"jsonrpc":"2.0","method":"tick"}\n')
            except OSError:
                break
            time.sleep(0.01)
PY
    PEER_PID=$!
    for _ in {1..250}; do
        [[ -S "$PEER_SOCKET" ]] && return
        sleep 0.02
    done
    return 1
}

@test "four commands map positional arguments to broker tools after initialization" {
    local tavily="$REAL_DOTFILES_DIR/bin/tvly-broker"
    local context="$REAL_DOTFILES_DIR/bin/ctx7-broker"
    run "$tavily" --socket "$SOCKET" search "one"
    assert_success
    [[ "$output" == "answer:tavily_search" ]]
    run "$tavily" --socket "$SOCKET" extract "https://one" "https://two"
    assert_success
    [[ "$output" == "answer:tavily_extract" ]]
    run "$context" --socket "$SOCKET" library "Library Name" "need docs"
    assert_success
    [[ "$output" == "answer:resolve-library-id" ]]
    run "$context" --socket "$SOCKET" docs "/org/lib" "need docs"
    assert_success
    [[ "$output" == "answer:query-docs" ]]
    "$PYTHON" - "$CALLS" <<'PY'
import json
import sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [call["method"] for call in calls] == [
    "notifications/initialized", "tools/call",
] * 4
assert [call["arguments"] for call in calls if call["method"] == "tools/call"] == [
    {"query": "one"},
    {"urls": ["https://one", "https://two"]},
    {"libraryName": "Library Name", "query": "need docs"},
    {"libraryId": "/org/lib", "query": "need docs"},
]
PY
}

@test "json output keeps the full tool result and additional arguments" {
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" --json --arguments '{"search_depth":"advanced"}' search structured
    assert_success
    [[ "$output" == *'"structuredContent":'* ]]
    [[ "$output" == *'"content":'* ]]
    [[ "$output" != *'"jsonrpc":'* ]]
    "$PYTHON" - "$CALLS" <<'PY'
import json
import sys
calls = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert calls[-1]["arguments"] == {"query": "structured", "search_depth": "advanced"}
PY
}

@test "invalid arguments fail before a tool call" {
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" --arguments '{"query":"override"}' search original
    assert_failure
    run "$REAL_DOTFILES_DIR/bin/ctx7-broker" --socket "$SOCKET" --arguments '[]' docs /id query
    assert_failure
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" --timeout nan search original
    assert_failure
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" extract
    assert_failure
    [[ ! -e "$CALLS" ]]
}

@test "tool errors and RPC errors fail with clean stdout" {
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" --json search tool-error
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"tool returned an error"* ]]
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" search rpc-error
    assert_failure
    [[ "$output" == *"upstream failed"* ]]
}

@test "slow upstream reports timeout without stdout" {
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" --timeout 0.3 search sleep
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"broker timed out"* ]]
    [[ "$stderr" != *"Traceback"* ]]
}

@test "upstream exit without reply reaches the deadline" {
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" --timeout 0.3 search disconnect
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"broker timed out"* ]]
}

@test "malformed upstream response reports a clean failure" {
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" --timeout 0.3 search malformed
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"malformed broker response"* ]]
}

@test "wrong response ID and absent socket report exact failures" {
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" search wrong-id
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"unexpected broker response ID"* ]]
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/ctx7-broker" --socket "$TEST_ROOT/absent.sock" docs /id query
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"broker unavailable"* ]]
}

@test "broker redacts credentials and text removes terminal controls" {
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" search credential
    assert_success
    [[ "$output" == "[REDACTED]" ]]
    [[ "$output" != *sentinel-credential-value* ]]
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" search escape
    assert_success
    [[ "$output" == $'safetext\nnext\tcolumn' ]]
    run "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$SOCKET" search structured-only
    assert_success
    [[ "$output" == '{"text": "safe\u009bvalue\u001b[31m"}' ]]
}

@test "large client request fails before broker forwarding" {
    "$PYTHON" - "$REAL_DOTFILES_DIR/bin/tvly-broker" "$SOCKET" <<'PY'
import json
import subprocess
import sys

urls = ["https://" + "é" * 40000] * 12
assert max(len(url.encode()) for url in urls) < 128 * 1024
assert sum(len(url.encode()) for url in urls) < 2 * 1024 * 1024
assert len(json.dumps(urls).encode()) > 1 << 20
result = subprocess.run([sys.argv[1], "--socket", sys.argv[2], "extract", *urls], capture_output=True, text=True)
assert result.returncode != 0, result.stdout
assert not result.stdout, result.stdout
assert "request is too large" in result.stderr, result.stderr
assert "Traceback" not in result.stderr, result.stderr
PY
    "$PYTHON" - "$CALLS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as calls:
    assert all(json.loads(line)["method"] != "tools/call" for line in calls)
PY
}

@test "large broker response fails without a traceback" {
    start_peer oversized
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$PEER_SOCKET" search query
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"broker response is too large"* ]]
    [[ "$stderr" != *"Traceback"* ]]
}

@test "notifications cannot extend the overall deadline" {
    start_peer notifications
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$PEER_SOCKET" --timeout 0.2 search query
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"broker timed out"* ]]
    [[ "$stderr" != *"Traceback"* ]]
}

@test "peer disconnect reports a clean failure" {
    start_peer disconnect
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/tvly-broker" --socket "$PEER_SOCKET" search query
    assert_failure
    [[ -z "$output" ]]
    [[ "$stderr" == *"broker disconnected"* ]]
    [[ "$stderr" != *"Traceback"* ]]
}

@test "caller does not need credential environment" {
    run env -u TAVILY_API_KEY -u CONTEXT7_API_KEY "$REAL_DOTFILES_DIR/bin/ctx7-broker" --socket "$SOCKET" docs /id query
    assert_success
    [[ "$output" == "answer:query-docs" ]]
}

@test "Context7 subcommand help shows both positional names without a traceback" {
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/ctx7-broker" library --help
    assert_success
    [[ "$output" == *"LIBRARY_NAME QUERY"* ]]
    [[ -z "$stderr" ]]
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/ctx7-broker" docs --help
    assert_success
    [[ "$output" == *"LIBRARY_ID QUERY"* ]]
    [[ -z "$stderr" ]]
}
