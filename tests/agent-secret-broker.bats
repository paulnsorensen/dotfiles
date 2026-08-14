#!/usr/bin/env bats

load test_helper

setup() {
    setup_test_env
    export TEST_ROOT="$TEST_HOME/agent-secret"
    export SOCKET="$TEST_ROOT/request.sock"
    export CONTROL="$TEST_ROOT/control.sock"
    export POLICY="$TEST_ROOT/policy.json"
    export CREDENTIAL="$TEST_ROOT/credential"
    export UPSTREAM="$TEST_ROOT/fake-mcp.py"
    export STARTED="$TEST_ROOT/upstream.started"
    export BROKER="$REAL_DOTFILES_DIR/bin/agent-secret-broker"
    export PROXY="$REAL_DOTFILES_DIR/bin/agent-secret-proxy"
    export CTL="$REAL_DOTFILES_DIR/bin/agent-secretctl"
    export PYTHON=/usr/bin/python3

    mkdir -p "$TEST_ROOT"
    [[ -x "$PYTHON" ]] || skip "/usr/bin/python3 is required"
    printf 'sentinel-credential-value' > "$CREDENTIAL"
    cat > "$UPSTREAM" <<EOF
#!$PYTHON
import json
import os
import sys
import time
from pathlib import Path

started = Path(sys.argv[1])
started.touch()
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        result = {"protocolVersion": "2025-06-18", "capabilities": {}}
    elif method == "slow":
        time.sleep(2.2)
        result = {"delayed": True}
    elif method == "notifications/initialized":
        continue
    elif method == "tools/list":
        result = {"tools": [{"name": "read.item"}, {"name": "write.item"}, {"name": "hidden.item"}]}
    elif method == "tools/call":
        name = request.get("params", {}).get("name")
        if name == "read.item":
            result = {"content": [{"text": "read-ok"}], "credential_env": os.environ.get("FAKE_SECRET", "missing")}
        elif name == "write.item":
            result = {"content": [{"text": "write-ok"}]}
        else:
            result = {"content": [{"text": "unexpected"}]}
    else:
        result = {"echo": method}
    if "id" in request:
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}, separators=(",", ":")), flush=True)
EOF
    chmod 700 "$UPSTREAM"
    cat > "$POLICY" <<EOF
{"consumer":"fixture","request_uid":$(id -u),"operator_uid":$(id -u),"upstream":{"argv":["$PYTHON","$UPSTREAM","$STARTED"],"credential_env":"FAKE_SECRET","credential_file":"$CREDENTIAL"},"tools":{"read":["read.item"],"write":["write.item"]}}
EOF
    chmod 600 "$POLICY" "$CREDENTIAL"
    "$BROKER" --policy "$POLICY" --socket "$SOCKET" --control-socket "$CONTROL" >"$TEST_ROOT/broker.log" 2>&1 &
    export BROKER_PID=$!
    for _ in {1..50}; do
        [[ -S "$SOCKET" && -S "$CONTROL" ]] && return
        sleep 0.02
    done
    cat "$TEST_ROOT/broker.log" >&2
    return 1
}

teardown() {
    if [[ -n "${BROKER_PID:-}" ]]; then
        kill "$BROKER_PID" 2>/dev/null || true
        wait "$BROKER_PID" 2>/dev/null || true
    fi
    teardown_test_env
}

proxy_call() {
    printf '%s\n' "$1" | "$PROXY" --socket "$SOCKET"
}

pending_nonce() {
    python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["pending"][0]["nonce"])'
}

@test "initialize, tools/list filtering, and allowed read never return the credential" {
    run proxy_call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
    assert_success
    [[ "$output" == *'"protocolVersion":"2025-06-18"'* ]]

    run proxy_call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    assert_success
    [[ "$output" == '{"id":2,"jsonrpc":"2.0","result":{"tools":[{"name":"read.item"},{"name":"write.item"}]}}' ]]

    run proxy_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read.item","arguments":{}}}'
    assert_success
    [[ "$output" == *'"text":"read-ok"'* ]]
    [[ "$output" == *'"credential_env":"[REDACTED]"'* ]]
    [[ "$output" != *'sentinel-credential-value'* ]]
}

@test "response delivery completes before the client session becomes idle" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import json
import sys
import threading
import time
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("agent_secret_broker", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class SlowConnection:
    def __init__(self):
        self.closed = threading.Event()
        self.payloads = []

    def sendall(self, payload):
        time.sleep(0.1)
        if self.closed.is_set():
            raise OSError("session closed before response delivery")
        self.payloads.append(payload)


connection = SlowConnection()
broker = SimpleNamespace(policy=SimpleNamespace(credential="sentinel"))
session = module.ClientSession(broker, connection)
session._methods["1"] = "initialize"
session._idle.clear()
ready = threading.Event()


def close_when_idle():
    ready.set()
    if session._idle.wait(1):
        connection.closed.set()


closer = threading.Thread(target=close_when_idle)
closer.start()
ready.wait()
session._upstream_line(
    json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"ready": True}}).encode()
)
closer.join()

assert connection.payloads == [
    b'{"id":1,"jsonrpc":"2.0","result":{"ready":true}}\n'
]
PY
    assert_success
}

@test "proxy loop returns cleanly when the selector loop raises OSError" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import pathlib
import socket
import sys
import tempfile

spec = importlib.util.spec_from_file_location("agent_secret_broker", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

sock_path = pathlib.Path(tempfile.mkdtemp()) / "proxy-test.sock"
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(sock_path))
server.listen(1)


class Args:
    socket = str(sock_path)
    consumer = None
    sub_socket = None


class FailingSelector:
    def register(self, fileobj, events, data=None):
        pass

    def unregister(self, fileobj):
        pass

    def get_map(self):
        return {"placeholder": True}

    def select(self, timeout=None):
        raise OSError("simulated failure")

    def close(self):
        pass


module.selectors.DefaultSelector = lambda: FailingSelector()

result = module.run_proxy(Args())
assert result == 1, result
server.close()
PY
    assert_success
}

@test "proxy drains an in-flight response after standard input closes" {
    run proxy_call '{"jsonrpc":"2.0","id":30,"method":"slow"}'
    assert_success
    [[ "$output" == '{"id":30,"jsonrpc":"2.0","result":{"delayed":true}}' ]]
}

@test "unknown tool is denied without forwarding or starting upstream" {
    run proxy_call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"hidden.item","arguments":{}}}'
    assert_success
    [[ "$output" == '{"error":{"code":-32602,"message":"tool denied"},"id":4,"jsonrpc":"2.0"}' ]]
    [[ ! -e "$STARTED" ]]
}

@test "write returns pending, rejects mismatch, approves once, and rejects replay" {
    request='{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"write.item","arguments":{}}}'
    run proxy_call "$request"
    assert_success
    [[ "$output" == *'"code":-32001'* ]]
    nonce="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["data"]["nonce"])')"

    run "$CTL" pending --socket "$CONTROL"
    assert_success
    [[ "$output" == *"$nonce"* ]]
    [[ "$output" != *'sentinel-credential-value'* ]]

    run "$CTL" approve --socket "$CONTROL" --nonce "$nonce" --approval wrong
    assert_failure
    [[ "$output" == *'"code":"mismatch"'* ]]

    run "$CTL" approve --socket "$CONTROL" --nonce "$nonce"
    assert_success
    [[ "$output" == "{\"action\":\"approve\",\"nonce\":\"$nonce\",\"ok\":true}" ]]
    run proxy_call "$request"
    assert_success
    [[ "$output" == *'"code":-32001'* ]]
    [[ ! -e "$STARTED" ]]

    run proxy_call "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"write.item\",\"arguments\":{},\"approval_nonce\":\"$nonce\"}}"
    assert_success
    [[ "$output" == *'"text":"write-ok"'* ]]
    [[ "$output" != *'sentinel-credential-value'* ]]
    run proxy_call "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"write.item\",\"arguments\":{},\"approval_nonce\":\"$nonce\"}}"
    assert_success
    [[ "$output" == *'"code":-32003'* ]]
    [[ "$output" == *'"message":"approval replay"'* ]]

    run "$CTL" approve --socket "$CONTROL" --nonce "$nonce"
    assert_failure
    [[ "$output" == *'"code":"replay"'* ]]
}

@test "control approval from a different UID is denied" {
    command -v runuser >/dev/null 2>&1 || skip "runuser is required"
    id nobody >/dev/null 2>&1 || skip "nobody user is required"
    ((EUID == 0)) || skip "different-UID test requires root"
    run proxy_call '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"write.item","arguments":{}}}'
    assert_success
    nonce="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["data"]["nonce"])')"
    run runuser -u nobody -- "$CTL" approve --socket "$CONTROL" --nonce "$nonce"
    assert_failure
    [[ "$output" == *'control request failed'* ]]

    run "$CTL" pending --socket "$CONTROL"
    assert_success
    [[ "$output" == *"$nonce"* ]]
}

@test "approval succeeds within TTL and is rejected once the TTL elapses" {
    local ttl_socket="$TEST_ROOT/ttl-request.sock"
    local ttl_control="$TEST_ROOT/ttl-control.sock"
    AGENT_SECRET_BROKER_APPROVAL_TTL=2 "$BROKER" --policy "$POLICY" --socket "$ttl_socket" --control-socket "$ttl_control" >"$TEST_ROOT/ttl-broker.log" 2>&1 &
    local ttl_pid=$!
    for _ in {1..50}; do
        [[ -S "$ttl_socket" && -S "$ttl_control" ]] && break
        sleep 0.02
    done

    run bash -c "printf '%s\n' \"\$1\" | '$PROXY' --socket '$ttl_socket'" _ '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"write.item","arguments":{}}}'
    assert_success
    within_nonce="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["data"]["nonce"])')"
    run "$CTL" approve --socket "$ttl_control" --nonce "$within_nonce"
    assert_success
    [[ "$output" == "{\"action\":\"approve\",\"nonce\":\"$within_nonce\",\"ok\":true}" ]]

    run bash -c "printf '%s\n' \"\$1\" | '$PROXY' --socket '$ttl_socket'" _ '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"write.item","arguments":{"expiry":true}}}'
    assert_success
    expiring_nonce="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["data"]["nonce"])')"
    for _ in {1..100}; do
        run "$CTL" approve --socket "$ttl_control" --nonce "$expiring_nonce"
        [[ "$output" == *'"code":"expired"'* ]] && break
        sleep 0.05
    done
    assert_failure
    [[ "$output" == *'"code":"expired"'* ]]

    kill "$ttl_pid" 2>/dev/null || true
    wait "$ttl_pid" 2>/dev/null || true
}

@test "socket mode is narrowed before ownership leaves the broker" {
    run "$PYTHON" - \
        "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" \
        "$TEST_ROOT/ordering.sock" <<'PY'
import importlib.util
import os
import pathlib
import sys

module_path, socket_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("broker_under_test", module_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# The systemd unit grants CAP_CHOWN/CAP_SETGID/CAP_SETUID only. Without
# CAP_FOWNER the kernel requires the caller to still own a file to chmod it,
# so handing the socket to another uid first makes the chmod fail with EPERM.
# Model exactly that: pretend to run as root and refuse a chmod issued after
# ownership has already moved away.
real_chmod = os.chmod
owner = {"uid": 0}

def guarded_chmod(path, mode):
    if owner["uid"] != 0:
        raise PermissionError(1, "Operation not permitted")
    real_chmod(path, mode)

def recording_chown(path, uid, gid):
    owner["uid"] = uid

os.chmod = guarded_chmod
os.chown = recording_chown
os.geteuid = lambda: 0

listener = module.Broker._bind(pathlib.Path(socket_path), 12345)
listener.close()
assert owner["uid"] == 12345, "ownership was never transferred"
print("bound")
PY
    assert_success
    [[ "$output" == *bound* ]]
}


@test "pending store rejects distinct requests after the per-consumer cap" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
store = module.PendingStore(SimpleNamespace(consumer="fixture"))
for index in range(module.PENDING_CAP):
    store.create_or_get("write.item", {"index": index})
try:
    store.create_or_get("write.item", {"index": module.PENDING_CAP})
except module.PendingStoreFull as exc:
    assert str(exc) == "pending store full"
else:
    raise AssertionError("pending store accepted an entry beyond the cap")
PY
    assert_success
}

@test "pending store rejects entries once retained bytes exceed the byte cap" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
store = module.PendingStore(SimpleNamespace(consumer="fixture"))
chunk = "x" * (module.PENDING_BYTES_CAP // 4)
accepted = 0
try:
    for index in range(module.PENDING_CAP):
        store.create_or_get("write.item", {"index": index, "padding": chunk})
        accepted += 1
except module.PendingStoreFull as exc:
    assert str(exc) == "pending store full"
else:
    raise AssertionError("pending store accepted unbounded retained bytes")
assert accepted < module.PENDING_CAP, accepted
PY
    assert_success
}

@test "malformed upstream output does not reset the backoff circuit" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import io
import pathlib
import sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
policy = SimpleNamespace(upstream=SimpleNamespace(), credential="secret")
session = module.UpstreamSession(policy, lambda _line: False, pathlib.Path("/tmp"))
session._restart_failures = 3
session._restart_after = 999999999.0
process = SimpleNamespace(stdout=io.BytesIO(b"not-json\n"))
session._process = process
session._read(process)
assert session._restart_failures == 3, session._restart_failures
assert session._restart_after == 999999999.0, session._restart_after
PY
    assert_success
}

@test "upstream EOF fails pending requests with a JSON-RPC error and logs a diagnostic" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import json
import pathlib
import sys
import tempfile
import threading
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

root = pathlib.Path(tempfile.mkdtemp())
script = root / "upstream.py"
script.write_text("import sys; sys.stdin.readline()\n")

policy = SimpleNamespace(
    upstream=SimpleNamespace(argv=(sys.executable, str(script)), credential_env="TOKEN"),
    credential="secret",
)


class Connection:
    def __init__(self):
        self.payloads = []
        self.lock = threading.Lock()

    def sendall(self, payload):
        with self.lock:
            self.payloads.append(payload)


broker = SimpleNamespace(policy=policy, upstream_home=root)
connection = Connection()
session = module.ClientSession(broker, connection)
assert session.forward({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
assert session._idle.wait(2), "upstream close was never observed"

messages = [json.loads(payload) for payload in connection.payloads]
assert messages == [
    {"jsonrpc": "2.0", "id": 1, "error": {"code": -32010, "message": "upstream closed"}}
], messages
PY
    assert_success
    [[ "$output" == *"upstream closed with pending request"* ]]
}

@test "upstream session respawns once after a crashed process" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import pathlib
import sys
import tempfile
import time
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
root = pathlib.Path(tempfile.mkdtemp())
script = root / "upstream.py"
script.write_text("import sys; sys.stdin.readline(); print('{}', flush=True)\n")
policy = SimpleNamespace(
    upstream=SimpleNamespace(argv=(sys.executable, str(script)), credential_env="TOKEN"),
    credential="secret",
)
lines = []
session = module.UpstreamSession(policy, lines.append, root)
session.send(b"{}\n")
time.sleep(module.UPSTREAM_RESTART_BASE * 1.5)
session.send(b"{}\n")
time.sleep(0.1)
session.close()
assert len(lines) == 2, lines
PY
    assert_success
}

@test "SIGTERM closes broker sockets" {
    local term_socket="$TEST_ROOT/term-request.sock"
    local term_control="$TEST_ROOT/term-control.sock"
    "$BROKER" --policy "$POLICY" --socket "$term_socket" --control-socket "$term_control" >"$TEST_ROOT/term-broker.log" 2>&1 &
    local term_pid=$!
    for _ in {1..50}; do
        [[ -S "$term_socket" && -S "$term_control" ]] && break
        sleep 0.02
    done
    [[ -S "$term_socket" && -S "$term_control" ]]
    kill -TERM "$term_pid"
    wait "$term_pid" 2>/dev/null || true
    [[ ! -e "$term_socket" ]]
    [[ ! -e "$term_control" ]]
}

@test "reader remains bound to the process it was given" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import io
import pathlib
import sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
policy = SimpleNamespace(upstream=SimpleNamespace(), credential="secret")
lines = []
session = module.UpstreamSession(policy, lines.append, pathlib.Path("/tmp"))
old = SimpleNamespace(stdout=io.BytesIO(b"old\n"))
new = SimpleNamespace(stdout=io.BytesIO(b"new\n"))
session._process = new
session._read(old)
assert lines == [b"old\n"], lines
PY
    assert_success
}

@test "crash-loop restart attempts stay behind the backoff circuit" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import io
import pathlib
import sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
spawned = []
class Stdin:
    def write(self, payload):
        return len(payload)
    def flush(self):
        pass
class DeadProcess:
    stdin = Stdin()
    stdout = io.BytesIO()
    def poll(self):
        return 1
    def wait(self, timeout=0):
        return 1
    def kill(self):
        pass
def spawn(*args, **kwargs):
    spawned.append(True)
    return DeadProcess()
module.subprocess.Popen = spawn
policy = SimpleNamespace(
    upstream=SimpleNamespace(argv=("/bin/false",), credential_env="TOKEN"),
    credential="secret",
)
session = module.UpstreamSession(policy, lambda _line: None, pathlib.Path("/tmp"))
session.send(b"{}\n")
for _ in range(8):
    try:
        session.send(b"{}\n")
    except RuntimeError:
        pass
assert len(spawned) == 2, spawned
PY
    assert_success
}

@test "failed upstream send rolls back request state and restores idle" {
    run "$PYTHON" - "$REAL_DOTFILES_DIR/scripts/agent-secret-broker.py" <<'PY'
import importlib.util
import pathlib
import sys
from types import SimpleNamespace
spec = importlib.util.spec_from_file_location("broker_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
class FailingUpstream:
    def send(self, _payload):
        raise RuntimeError("upstream unavailable")
class Connection:
    def __init__(self):
        self.payloads = []
    def sendall(self, payload):
        self.payloads.append(payload)
policy = SimpleNamespace(credential="secret")
broker = SimpleNamespace(policy=policy, upstream_home=pathlib.Path("/tmp"))
connection = Connection()
session = module.ClientSession(broker, connection)
session._upstream = FailingUpstream()
session._methods["1"] = "initialize"
session._idle.clear()
assert not session.forward({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
assert session._methods["1"] == "initialize"
assert not session._idle.is_set()
session._methods.clear()
assert not session.forward({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
assert session._methods == {}
assert session._idle.is_set()
PY
    assert_success
}
