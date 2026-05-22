#!/usr/bin/env bats
# Tests for bin/serena-mux — per-(project root, harness) serena daemon coalescer.
#
# Strategy: stub `serena` and `uvx` on PATH. The stub serena actually binds a
# TCP port so the wrapper's listener-poll loop sees a real LISTEN socket. The
# stub uvx just records the URL it was asked to bridge to, then exits 0 so
# the wrapper's terminal `exec uvx …` returns cleanly without trying to talk
# MCP framing to anything.

load test_helper

setup() {
    setup_test_env

    # Sandbox the runtime dir under TEST_HOME so concurrent runs don't collide
    # with the user's real ~/serena-mux state.
    export SERENA_MUX_RUNTIME_DIR="$TEST_HOME/serena-mux-state"

    # Each test gets its own fake-bin dir prepended to PATH. Order matters:
    # FAKE_BIN must outrank the real serena/uvx that may exist on this host.
    FAKE_BIN="$TEST_HOME/fake-bin"
    mkdir -p "$FAKE_BIN"
    export PATH="$FAKE_BIN:$PATH"

    # Stub uvx: record the args + exit 0. Don't actually bridge.
    export MOCK_UVX_LOG="$TEST_HOME/uvx-args.log"
    cat >"$FAKE_BIN/uvx" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MOCK_UVX_LOG"
exit 0
EOF
    chmod +x "$FAKE_BIN/uvx"

    # Stub serena: read --port out of args, bind a TCP listener, idle until
    # signaled. Python because bash can't bind a TCP socket natively.
    cat >"$FAKE_BIN/serena" <<'EOF'
#!/usr/bin/env bash
port=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) port="$2"; shift 2 ;;
        --port=*) port="${1#*=}"; shift ;;
        *) shift ;;
    esac
done
[[ -z "$port" ]] && { echo "stub serena: no --port given" >&2; exit 1; }
exec python3 - "$port" <<'PYEOF'
import socket, signal, sys, time
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(4)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
signal.signal(signal.SIGINT,  lambda *_: sys.exit(0))
while True:
    try:
        c, _ = s.accept()
        c.close()
    except Exception:
        time.sleep(0.05)
PYEOF
EOF
    chmod +x "$FAKE_BIN/serena"

    # Working dir = a git repo so root resolution is deterministic.
    REPO="$TEST_HOME/repo"
    mkdir -p "$REPO"
    (
        cd "$REPO" || exit 1
        git init --quiet
        git config user.email "test@example.com"
        git config user.name  "Test"
    )
    cd "$REPO" || exit 1
}

teardown() {
    # Kill any daemon stubs the test may have spawned.
    if [[ -n "${SERENA_MUX_RUNTIME_DIR:-}" && -d "$SERENA_MUX_RUNTIME_DIR" ]]; then
        find "$SERENA_MUX_RUNTIME_DIR" -name pid -print0 2>/dev/null \
            | xargs -0 -I{} sh -c 'pid=$(cat "{}" 2>/dev/null); [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true'
    fi
    teardown_test_env
}

# --- Dependency checks ---------------------------------------------------

@test "serena-mux: exits 2 when serena binary is missing" {
    rm "$FAKE_BIN/serena"
    # Hide the real serena too so the check actually fails, but keep the
    # dotfiles bin/ dir on PATH so `serena-mux` itself is findable.
    PATH="$FAKE_BIN:$REAL_DOTFILES_DIR/bin:/usr/bin:/bin" run serena-mux
    [ "$status" -eq 2 ]
    [[ "$output" == *"serena binary not found"* ]]
}

@test "serena-mux: exits 3 when uvx is missing" {
    rm "$FAKE_BIN/uvx"
    PATH="$FAKE_BIN:$REAL_DOTFILES_DIR/bin:/usr/bin:/bin" run serena-mux
    [ "$status" -eq 3 ]
    [[ "$output" == *"uvx not found"* ]]
}

# --- Identity & lifecycle ------------------------------------------------

@test "serena-mux: spawns a daemon and bridges via uvx" {
    run serena-mux
    [ "$status" -eq 0 ]

    # Find the per-slug state dir
    state_dir=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
    [ -n "$state_dir" ]
    [ -f "$state_dir/pid" ]
    [ -f "$state_dir/port" ]

    pid=$(cat "$state_dir/pid")
    port=$(cat "$state_dir/port")
    [ -n "$pid" ]
    [ -n "$port" ]

    # Daemon should be alive and listening.
    kill -0 "$pid"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null

    # uvx was invoked with the right URL.
    grep -q "http://127.0.0.1:$port/mcp" "$MOCK_UVX_LOG"
    grep -q "streamablehttp" "$MOCK_UVX_LOG"
}

@test "serena-mux: second invocation reuses an alive daemon" {
    run serena-mux
    [ "$status" -eq 0 ]
    state_dir=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
    first_pid=$(cat "$state_dir/pid")
    first_port=$(cat "$state_dir/port")

    # Second call: pidfile is alive → no respawn.
    run serena-mux
    [ "$status" -eq 0 ]
    [ "$(cat "$state_dir/pid")"  = "$first_pid" ]
    [ "$(cat "$state_dir/port")" = "$first_port" ]

    # Only one PID alive in the state tree.
    [ "$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 ]
}

@test "serena-mux: reaps a stale pidfile and respawns" {
    # Seed a slug-shaped state dir with a definitely-dead pidfile.
    # We can't compute the slug here without duplicating shasum logic, so
    # let the wrapper allocate the dir first, kill its daemon, then re-invoke.
    run serena-mux
    [ "$status" -eq 0 ]
    state_dir=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
    old_pid=$(cat "$state_dir/pid")
    kill -9 "$old_pid" 2>/dev/null || true
    # Wait until the OS reaps the dead pid so `kill -0` returns false.
    for _ in $(seq 1 50); do
        kill -0 "$old_pid" 2>/dev/null || break
        sleep 0.05
    done

    run serena-mux
    [ "$status" -eq 0 ]
    new_pid=$(cat "$state_dir/pid")
    [ "$new_pid" != "$old_pid" ]
    kill -0 "$new_pid"
}

@test "serena-mux: different harnesses get different daemons in the same repo" {
    SERENA_MUX_HARNESS=claude-code run serena-mux
    [ "$status" -eq 0 ]
    SERENA_MUX_HARNESS=codex      run serena-mux
    [ "$status" -eq 0 ]
    count=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    [ "$count" = 2 ]
}

@test "serena-mux: invocation from a subdir reuses the worktree daemon" {
    run serena-mux
    [ "$status" -eq 0 ]
    state_dir=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
    first_port=$(cat "$state_dir/port")

    mkdir -p "$REPO/nested/deep"
    cd "$REPO/nested/deep"
    run serena-mux
    [ "$status" -eq 0 ]

    count=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    [ "$count" = 1 ]
    [ "$(cat "$state_dir/port")" = "$first_port" ]
}

@test "serena-mux: concurrent invocations spawn exactly one daemon" {
    # Fire 4 wrappers in parallel; spawn-lock should serialize them.
    serena-mux & p1=$!
    serena-mux & p2=$!
    serena-mux & p3=$!
    serena-mux & p4=$!
    wait "$p1" "$p2" "$p3" "$p4"

    # Exactly one state dir, one alive pid.
    count=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
    [ "$count" = 1 ]
    state_dir=$(find "$SERENA_MUX_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
    pid=$(cat "$state_dir/pid")
    kill -0 "$pid"

    # All four uvx invocations recorded.
    [ "$(wc -l < "$MOCK_UVX_LOG" | tr -d ' ')" -ge 4 ]
}

@test "serena-mux: writes a 0700 runtime root" {
    run serena-mux
    [ "$status" -eq 0 ]
    perms=$(stat -f '%Lp' "$SERENA_MUX_RUNTIME_DIR" 2>/dev/null || stat -c '%a' "$SERENA_MUX_RUNTIME_DIR")
    [ "$perms" = "700" ]
}
