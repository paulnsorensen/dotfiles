#!/usr/bin/env bats

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
GATE_SLOT="$DOTFILES_DIR/bin/gate-slot"
TMPROOT=

setup() {
    command -v sem >/dev/null 2>&1 || skip "GNU sem is required"
    TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-slot.XXXXXX")"
}

teardown() {
    if [[ -n "$TMPROOT" && -d "$TMPROOT" ]]; then
        find "$TMPROOT" -type f -name '*.pid' -exec sh -c 'kill "$(cat "$1")" 2>/dev/null || true' _ {} \; 2>/dev/null || true
        rm -rf "$TMPROOT"
    fi
}

wait_for_files() {
    python3 - "$@" <<'PY'
import pathlib
import sys
import time

paths = [pathlib.Path(value) for value in sys.argv[1:]]
deadline = time.monotonic() + 30
while not all(path.exists() and path.stat().st_size for path in paths):
    if time.monotonic() >= deadline:
        raise SystemExit(f"Startup handshake expires: {paths}")
    time.sleep(0.02)
PY
}

@test "gate-slot supports help and version" {
    run "$GATE_SLOT" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"gate-slot"* ]]

    run "$GATE_SLOT" run --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"up to 3 wait attempts"* ]]

    run "$GATE_SLOT" --version
    [[ "$status" -eq 0 ]]
    [[ "$output" == gate-slot* ]]
}

@test "AC-1 streams stdout and stderr and returns the command exit code" {
    local stdout="$TMPROOT/stdout"
    local stderr="$TMPROOT/stderr"
    local release="$TMPROOT/release"
    local helper="$TMPROOT/streams.py"
    cat >"$helper" <<'PY'
import pathlib
import sys
import time

print("stdout", flush=True)
print("stderr", file=sys.stderr, flush=True)
release = pathlib.Path(sys.argv[1])
while not release.exists():
    time.sleep(0.01)
raise SystemExit(7)
PY
    local -a command=(run --slots 2 --name "gate-slot-ac1-$BATS_TEST_NUMBER" -- python3 "$helper" "$release")
    "$GATE_SLOT" "${command[@]}" >"$stdout" 2>"$stderr" &
    local runner=$!
    printf '%s' "$runner" >"$TMPROOT/wrapper.pid"
    wait_for_files "$stdout" "$stderr"
    [[ "$(cat "$stdout")" == "stdout" ]]
    [[ "$(cat "$stderr")" == "stderr" ]]
    : >"$release"
    local rc=0
    wait "$runner" || rc=$?
    [[ "$rc" -eq 7 ]]
}

@test "AC-2 caps six concurrent commands at two slots and runs all commands" {
    local state="$TMPROOT/state"
    local marker="$TMPROOT/markers"
    local helper="$TMPROOT/job.py"
    local name="gate-slot-ac2-$BATS_TEST_NUMBER-$$"
    cat >"$helper" <<'PY'
import fcntl
import pathlib
import sys
import time

state = pathlib.Path(sys.argv[1])
marker = pathlib.Path(sys.argv[2])
with state.open("a+") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    stream.seek(0)
    running, maximum = (map(int, (stream.read() or "0 0").split()))
    running += 1
    maximum = max(maximum, running)
    stream.seek(0)
    stream.truncate()
    stream.write(f"{running} {maximum}")
    stream.flush()
    fcntl.flock(stream, fcntl.LOCK_UN)
with marker.open("a") as stream:
    stream.write(sys.argv[3] + "\n")
time.sleep(0.25)
with state.open("a+") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    stream.seek(0)
    running, maximum = map(int, stream.read().split())
    stream.seek(0)
    stream.truncate()
    stream.write(f"{running - 1} {maximum}")
    stream.flush()
    fcntl.flock(stream, fcntl.LOCK_UN)
PY
    printf '0 0' >"$state"
    local -a pids=()
    local i
    for i in {1..6}; do
        "$GATE_SLOT" run --slots 2 --name "$name" -- \
            python3 "$helper" "$state" "$marker" "$i" >"$TMPROOT/out-$i" 2>&1 &
        pids+=("$!")
    done
    local rc=0
    for i in "${pids[@]}"; do
        wait "$i" || rc=$?
    done
    [[ "$rc" -eq 0 ]]
    [[ "$(wc -l <"$marker" | tr -d ' ')" -eq 6 ]]
    [[ "$(awk '{print $2}' "$state")" -le 2 ]]
}

@test "AC-3 SIGKILL of gate-slot leaves its descendant process dead" {
    local pidfile="$TMPROOT/child.pid"
    local helper="$TMPROOT/child.py"
    cat >"$helper" <<'PY'
import pathlib
import signal
import subprocess
import sys

child = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(30)",
    ]
)
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
child.wait()
PY
    env TMPDIR="$TMPROOT" "$GATE_SLOT" run --slots 1 --name "gate-slot-ac3-$BATS_TEST_NUMBER-$$" -- \
        python3 "$helper" "$pidfile" >"$TMPROOT/out" 2>&1 &
    local wrapper=$!
    printf '%s' "$wrapper" >"$TMPROOT/wrapper.pid"
    wait_for_files "$pidfile"
    local child
    child="$(<"$pidfile")"
    kill -KILL "$wrapper"
    wait "$wrapper" 2>/dev/null || true
    for _ in {1..40}; do
        if ! kill -0 "$child" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done
    ! kill -0 "$child" 2>/dev/null
    [[ -z "$(find "$TMPROOT" -mindepth 1 -maxdepth 1 -type d -name 'gate-slot-marker-*' -print -quit)" ]]
}



@test "guardian loss kills a running command" {
    local pidfile="$TMPROOT/running-child.pid"
    local helper="$TMPROOT/running-child.py"
    cat >"$helper" <<'PY'
import pathlib
import signal
import subprocess
import sys
import time

child = subprocess.Popen(
    [
        sys.executable,
        "-c",
        "import signal,time; signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(30)",
    ]
)
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
child.wait()
PY
    env TMPDIR="$TMPROOT" "$GATE_SLOT" run --slots 1 --name "gate-slot-guardian-running-$BATS_TEST_NUMBER-$$" -- python3 "$helper" "$pidfile" >"$TMPROOT/out" 2>&1 &
    local wrapper=$!
    printf '%s' "$wrapper" >"$TMPROOT/wrapper.pid"
    wait_for_files "$pidfile"
    local child
    child="$(<"$pidfile")"
    local guardian=
    for _ in {1..40}; do
        guardian="$(pgrep -P "$wrapper" | head -n1 || true)"
        [[ -n "$guardian" ]] && break
        sleep 0.05
    done
    [[ -n "$guardian" ]]
    kill -KILL "$guardian"
    local rc=0
    wait "$wrapper" || rc=$?
    [[ "$rc" -eq 127 ]]
    for _ in {1..40}; do
        ! kill -0 "$child" 2>/dev/null && break
        sleep 0.05
    done
    ! kill -0 "$child" 2>/dev/null
}

@test "guardian loss kills descendants after sem exits" {
    local pidfile="$TMPROOT/late-child.pid"
    local helper="$TMPROOT/late-child.py"
    cat >"$helper" <<'PY'
import pathlib
import subprocess
import sys

child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
pathlib.Path(sys.argv[1]).write_text(str(child.pid))
PY
    env TMPDIR="$TMPROOT" "$GATE_SLOT" run --slots 1 --name "gate-slot-late-child-$BATS_TEST_NUMBER-$$" -- \
        python3 "$helper" "$pidfile" >"$TMPROOT/out" 2>&1 &
    local wrapper=$!
    printf '%s' "$wrapper" >"$TMPROOT/wrapper.pid"
    wait_for_files "$pidfile"
    local child
    child="$(<"$pidfile")"
    kill -KILL "$wrapper"
    wait "$wrapper" 2>/dev/null || true
    for _ in {1..40}; do
        ! kill -0 "$child" 2>/dev/null && break
        sleep 0.05
    done
    ! kill -0 "$child" 2>/dev/null
}

@test "guardian loss cancels a queued command" {
    local holder_marker="$TMPROOT/guardian-holder.marker"
    local queued_marker="$TMPROOT/guardian-queued.marker"
    local name="gate-slot-guardian-queued-$BATS_TEST_NUMBER-$$"
    local release="$TMPROOT/guardian-holder.release"
    env TMPDIR="$TMPROOT" "$GATE_SLOT" run --slots 1 --name "$name" -- sh -c "printf holder >'$holder_marker'; while [ ! -e '$release' ]; do sleep 0.02; done" >"$TMPROOT/holder.out" 2>&1 &
    local holder=$!
    printf '%s' "$holder" >"$TMPROOT/holder.pid"
    wait_for_files "$holder_marker"
    env TMPDIR="$TMPROOT" "$GATE_SLOT" run --slots 1 --name "$name" --timeout 5 -- sh -c "printf queued >'$queued_marker'" &
    local wrapper=$!
    local guardian=
    local queued_sem=
    for _ in {1..40}; do
        for marker_dir in "$TMPROOT"/gate-slot-marker-*; do
            [[ -f "$marker_dir/sem" && ! -f "$marker_dir/started" ]] || continue
            queued_sem="$marker_dir/sem"
            break
        done
        if [[ -n "$queued_sem" ]]; then
            guardian="$(ps -o ppid= -p "$(cat "$queued_sem")" | tr -d ' ')"
        fi
        [[ -n "$guardian" ]] && break
        sleep 0.05
    done
    [[ -n "$guardian" ]]
    [[ -f "$queued_sem" ]]
    [[ ! -e "$queued_marker" ]]
    kill -KILL "$guardian"
    local rc=0
    wait "$wrapper" || rc=$?
    [[ "$rc" -eq 127 ]]
    [[ ! -e "$queued_marker" ]]
    : >"$release"
    wait "$holder" || true
}

@test "SIGTERM forwards SIGINT to an announced queued waiter" {
    local fakebin="$TMPROOT/fakebin"
    local queue="$TMPROOT/queue"
    local cancelled="$TMPROOT/cancelled"
    local fake_marker="$TMPROOT/fake.marker"
    local fake_name="gate-slot-ac4-fake-$BATS_TEST_NUMBER-$$"
    mkdir -p "$fakebin"
    cat >"$fakebin/sem" <<'SH'
#!/bin/sh
printf queued >"$GATE_SLOT_FAKE_QUEUE"
    trap 'printf cancelled >"$GATE_SLOT_FAKE_CANCELLED"; exit 130' INT
    trap 'printf term >"$GATE_SLOT_FAKE_TERM"; exit 143' TERM
while :; do
    sleep 0.05
done
SH
    chmod +x "$fakebin/sem"
    local -a fake_command=(
        run --slots 1 --name "$fake_name" --timeout 5 --
        sh -c "printf ran >'$fake_marker'"
    )
    local term_received="$TMPROOT/term-received"
    PATH="$fakebin:$PATH" GATE_SLOT_FAKE_QUEUE="$queue" GATE_SLOT_FAKE_CANCELLED="$cancelled" GATE_SLOT_FAKE_TERM="$term_received" "$GATE_SLOT" "${fake_command[@]}" &
    local queued=$!
    for _ in {1..40}; do
        [[ -e "$queue" ]] && break
        sleep 0.05
    done
    [[ -e "$queue" ]]
    kill -TERM "$queued"
    for _ in {1..40}; do
        [[ -e "$cancelled" ]] && break
        sleep 0.05
    done
    [[ -e "$cancelled" ]]
    [[ "$(<"$cancelled")" == cancelled ]]
    [[ ! -e "$term_received" ]]
    ! kill -0 "$queued" 2>/dev/null
    local rc=0
    wait "$queued" || rc=$?
    [[ "$rc" -eq 130 ]]
    [[ ! -e "$fake_marker" ]]

}

@test "timeout retries three wait attempts with bounded backoff" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
fakebin = root / "fakebin"
fakebin.mkdir()
sem = fakebin / "sem"
attempts = root / "attempts"
sem.write_text("""#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ["ATTEMPTS"], "a") as output:
    output.write(json.dumps([time.monotonic(), sys.argv[1:]]) + "\\n")
print("Semaphore timed out.", file=sys.stderr)
raise SystemExit(1)
""")
sem.chmod(0o755)
launcher = root / "clock.py"
waits = root / "waits"
launcher.write_text("""
import os, runpy, select, sys, time
clock = 0.0
real_now, real_select = time.monotonic, select.select
def now():
    return clock if sys._getframe(1).f_code.co_name == "guardian_main" else real_now()
def wait(readers, writers, errors, timeout):
    global clock
    if sys._getframe(1).f_code.co_name == "guardian_main":
        with open(os.environ["WAITS"], "a") as output:
            output.write(str(timeout) + "\\n")
        clock += timeout
        return real_select(readers, writers, errors, 0)
    return real_select(readers, writers, errors, timeout)
time.monotonic, select.select = now, wait
gate = sys.argv.pop(1)
runpy.run_path(gate, run_name="__main__")
""")
result = subprocess.run(
    [sys.executable, "-B", str(launcher), gate, "run", "--slots", "1", "--timeout", "0.01", "--", "true"],
    env=dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"],
             ATTEMPTS=str(attempts), WAITS=str(waits)),
    capture_output=True, timeout=30,
)
assert result.returncode == 75, result
records = [json.loads(line) for line in attempts.read_text().splitlines()]
assert len(records) == 3, records
for _, argv in records:
    index = argv.index("--semaphoretimeout")
    assert argv[index + 1] == "-0.01", argv
requested = [float(value) for value in waits.read_text().splitlines()]
assert len(requested) == 2, requested
assert all(abs(actual - expected) < 1e-9 for actual, expected in zip(requested, (0.1, 0.2))), requested
PY
    [[ "$status" -eq 0 ]]
}

@test "timeout does not retry a command after launch" {
    local fakebin="$TMPROOT/fakebin"
    local attempts="$TMPROOT/attempts"
    local marker="$TMPROOT/started.marker"
    mkdir -p "$fakebin"
    : >"$attempts"
    cat >"$fakebin/sem" <<'SH'
#!/bin/sh
count=$(($(wc -l <"$GATE_SLOT_FAKE_ATTEMPTS") + 1))
printf '%s\n' "$count" >>"$GATE_SLOT_FAKE_ATTEMPTS"
last=
for argument do
    last="$argument"
done
eval "$last"
printf 'Semaphore timed out.\n' >&2
exit 1
SH
    chmod +x "$fakebin/sem"
    run env PATH="$fakebin:$PATH" GATE_SLOT_FAKE_ATTEMPTS="$attempts" "$GATE_SLOT" \
        run --slots 1 --name "gate-slot-started-$BATS_TEST_NUMBER-$$" --timeout 0.01 -- \
        sh -c "printf ran >'$marker'"
    [[ "$status" -eq 1 ]]
    [[ "$(<"$attempts")" == 1 ]]
    [[ "$(<"$marker")" == ran ]]
}

@test "timeout returns 75 without running the queued command" {
    local marker="$TMPROOT/timeout.marker"
    local holder_marker="$TMPROOT/holder.marker"
    local name="gate-slot-timeout-$BATS_TEST_NUMBER-$$"
    local release="$TMPROOT/holder.release"
    "$GATE_SLOT" run --slots 1 --name "$name" -- \
        sh -c "printf holder >'$holder_marker'; while [ ! -e '$release' ]; do sleep 0.02; done" >"$TMPROOT/holder.out" 2>&1 &
    local holder=$!
    printf '%s' "$holder" >"$TMPROOT/holder.pid"
    wait_for_files "$holder_marker"
    run "$GATE_SLOT" run --slots 1 --name "$name" --timeout 0.1 -- \
        sh -c "printf ran >'$marker'"
    [[ "$status" -eq 75 ]]
    [[ ! -e "$marker" ]]
    : >"$release"
    wait "$holder" || true
}

@test "timeout preserves a semaphore setup failure" {
    local fakebin="$TMPROOT/bin"
    mkdir -p "$fakebin"
    cat >"$fakebin/sem" <<'SH'
#!/bin/sh
printf 'setup failed\n' >&2
exit 1
SH
    chmod +x "$fakebin/sem"
    run env PATH="$fakebin:$PATH" "$GATE_SLOT" run --slots 1 --timeout 1 -- true
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"setup failed"* ]]
}

@test "marker uses a private directory and cleans it after the command" {
    run env TMPDIR="$TMPROOT" "$GATE_SLOT" run --slots 1 -- \
        python3 -c 'import glob, os, stat; paths=glob.glob(os.path.join(os.environ["TMPDIR"], "gate-slot-marker-*")); assert paths and all(stat.S_IMODE(os.stat(path).st_mode) == 0o700 for path in paths); print("secure")'
    [[ "$status" -eq 0 ]]
    [[ "$output" == *secure* ]]
    [[ -z "$(find "$TMPROOT" -mindepth 1 -maxdepth 1 -type d -name 'gate-slot-marker-*' -print -quit)" ]]
}

@test "argv with spaces, quotes, empty, and duplicate arguments reaches the command unchanged" {
    local -a command=(
        run --slots 1 --name "gate-slot-argv-$BATS_TEST_NUMBER" --
        python3 -c 'import sys; print("|".join(sys.argv[1:]))'
        "a word" "" "a word" 'a"quote' "a'quote"
    )
    run "$GATE_SLOT" "${command[@]}"
    [[ "$status" -eq 0 ]]
    local expected='a word||a word|a"quote|a'\''quote'
    [[ "$output" == "$expected" ]]
}

@test "validation rejects invalid options and preserves command exit 75" {
    run "$GATE_SLOT" run --slots 0 -- true
    [[ "$status" -ne 0 ]]

    run "$GATE_SLOT" run --slots 1 --timeout nan -- true
    [[ "$status" -ne 0 ]]

    run "$GATE_SLOT" run --slots 1 --name "" -- true
    [[ "$status" -ne 0 ]]

    run "$GATE_SLOT" run --slots 1 -- python3 -c 'raise SystemExit(75)'
    [[ "$status" -eq 75 ]]
}

@test "just check routes its parallel leg through gate-slot" {
    run just --justfile "$DOTFILES_DIR/justfile" --dry-run check
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"gate-slot run --slots 1 --name dotfiles-check --"* ]]
    [[ "$output" == *"parallel -k --group just :::"* ]]
}

@test "wrapper death cleans resistant descendants after the sem leader exits" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
fakebin = root / "fakebin"
fakebin.mkdir()
sem = fakebin / "sem"
sem.write_text("""#!/usr/bin/env python3
import os, pathlib, signal, subprocess, sys
child = subprocess.Popen([sys.executable, "-c", "import signal,time; signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"])
pathlib.Path(os.environ["CHILD_PID"]).write_text(str(child.pid))
""")
sem.chmod(0o755)
env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"], TMPDIR=str(root))
def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
for stop in (signal.SIGKILL, signal.SIGTERM):
    pidfile = root / f"child-{stop}.pid"
    env["CHILD_PID"] = str(pidfile)
    with (root / "output").open("wb") as output:
        wrapper = subprocess.Popen([gate, "run", "--slots", "1", "--", "true"], env=env, stdout=output, stderr=output)
        child = None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                markers = list(root.glob("gate-slot-marker-*/sem"))
                if pidfile.exists() and markers and not alive(int(markers[0].read_text())):
                    break
                time.sleep(0.02)
            else:
                raise AssertionError("sem leader did not exit")
            child = int(pidfile.read_text())
            assert alive(child), "descendant must remain alive before cancellation"
            wrapper.send_signal(stop)
            wrapper.wait(timeout=4)
            deadline = time.monotonic() + 4
            while alive(child) and time.monotonic() < deadline:
                time.sleep(0.02)
            assert not alive(child), "descendant survives wrapper cancellation"
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait()
            if child and alive(child):
                os.kill(child, signal.SIGKILL)
PY
    [[ "$status" -eq 0 ]]
}

@test "closed stderr sink retains command ownership and exit status" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
for cancel in (False, True):
    pidfile = root / f"relay-{cancel}.pid"
    emitted = root / f"relay-{cancel}.emitted"
    release = root / f"relay-{cancel}.release"
    helper = (
        "import os,pathlib,signal,sys,time; "
        "signal.signal(signal.SIGINT, signal.SIG_IGN); "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
        "print('output',file=sys.stderr,flush=True); "
        "pathlib.Path(sys.argv[2]).touch(); release=pathlib.Path(sys.argv[3]); "
        "exec('while not release.exists(): time.sleep(0.01)'); sys.exit(7)"
    )
    wrapper = subprocess.Popen(
        [gate, "run", "--slots", "1", "--name", str(pidfile), "--", sys.executable, "-c", helper, str(pidfile), str(emitted), str(release)],
        env=dict(os.environ, TMPDIR=str(root)), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    wrapper.stderr.close()
    child = None
    try:
        deadline = time.monotonic() + 30
        while not emitted.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert emitted.exists(), "workload does not confirm stderr output"
        child = int(pidfile.read_text())
        if cancel:
            assert wrapper.poll() is None, "relay error aborts supervision"
            markers = list(root.glob("gate-slot-marker-*/started"))
            assert markers, "relay error removes cleanup identity"
            wrapper.kill()
        else:
            release.touch()
        result = wrapper.wait(timeout=5)
        if not cancel:
            assert result == 7, result
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            raise AssertionError("workload survives cleanup")
    finally:
        if wrapper.poll() is None:
            wrapper.kill()
            wrapper.wait()
        if child:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
PY
    [[ "$status" -eq 0 ]]
}

@test "sem launch waits for publication and exits on guardian loss" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
fakebin = root / "fakebin"
fakebin.mkdir()
sem = fakebin / "sem"
sem.write_text("#!/bin/sh\nprintf ran >\"$EXECUTED\"\nsleep 30\n")
sem.chmod(0o755)
launcher = root / "publication.py"
launcher.write_text("""
import os, pathlib, runpy, signal, subprocess, sys, time
original_popen = subprocess.Popen
original_write = pathlib.Path.write_text
def observe(*args, **kwargs):
    process = original_popen(*args, **kwargs)
    with open(os.environ["OBSERVED"], "w") as output:
        output.write(str(process.pid))
    time.sleep(0.2)
    return process
def publish(path, text, *args, **kwargs):
    if path.name != "sem":
        return original_write(path, text, *args, **kwargs)
    mode = os.environ["MODE"]
    if mode == "error":
        raise OSError("publication failure")
    if mode == "after":
        original_write(path, text, *args, **kwargs)
    os.kill(os.getpid(), signal.SIGKILL)
subprocess.Popen = observe
pathlib.Path.write_text = publish
gate = sys.argv.pop(1)
runpy.run_path(gate, run_name="__main__")
""")
def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
for mode in ("error", "before", "after"):
    observed, executed = root / f"{mode}.pid", root / f"{mode}.executed"
    env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"],
               TMPDIR=str(root), OBSERVED=str(observed), EXECUTED=str(executed), MODE=mode)
    with (root / "output").open("wb") as output:
        wrapper = subprocess.Popen(
            [sys.executable, str(launcher), gate, "run", "--slots", "1", "--", "true"],
            env=env, stdout=output, stderr=output,
        )
        child = None
        try:
            assert wrapper.wait(timeout=5) == 127
            assert observed.exists(), "failure did not reach process creation"
            child = int(observed.read_text())
            deadline = time.monotonic() + 5
            while alive(child) and time.monotonic() < deadline:
                time.sleep(0.02)
            assert not alive(child), f"unreleased sem survives {mode}"
            assert not executed.exists(), f"sem runs before publication: {mode}"
            assert not list(root.glob("gate-slot-marker-*"))
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait()
            if child and alive(child):
                os.killpg(child, signal.SIGKILL)
PY
    [[ "$status" -eq 0 ]]
}

@test "cancellation and wrapper death stop retries during backoff" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
fakebin = root / "fakebin"
fakebin.mkdir()
sem = fakebin / "sem"
sem.write_text("""#!/usr/bin/env python3
import os, sys
with open(os.environ["ATTEMPTS"], "a") as output:
    output.write("attempt\\n")
print("Semaphore timed out.", file=sys.stderr)
raise SystemExit(1)
""")
sem.chmod(0o755)
for stop in (signal.SIGTERM, signal.SIGKILL):
    attempts = root / f"attempts-{stop}"
    env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ["PATH"],
               TMPDIR=str(root), ATTEMPTS=str(attempts))
    with (root / "output").open("wb") as output:
        wrapper = subprocess.Popen(
            [gate, "run", "--slots", "1", "--timeout", "0.01", "--", "true"],
            env=env, stdout=output, stderr=output,
        )
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if attempts.exists() and attempts.read_text() and not list(root.glob("gate-slot-marker-*/sem")):
                    break
                time.sleep(0.001)
            else:
                raise AssertionError("backoff was not observed")
            wrapper.send_signal(stop)
            assert wrapper.wait(timeout=5) == (130 if stop == signal.SIGTERM else -stop)
            time.sleep(0.4)
            assert attempts.read_text().splitlines() == ["attempt"]
            assert not list(root.glob("gate-slot-marker-*"))
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait()
PY
    [[ "$status" -eq 0 ]]
}

@test "GNU replacement expressions remain literal in argv and temporary paths" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
sentinel = root / "injected"
arguments = ["{= $_='changed' =}", "{1}", "{}", "{#}", "", "a word",
             "{= system('touch " + str(sentinel) + "'); $_='changed' =}"]
temporary = root / "{= $_='changed' =}"
temporary.mkdir()
result = subprocess.run(
    [gate, "run", "--slots", "1", "--name", str(root), "--",
     sys.executable, "-c", "import json,sys; print(json.dumps(sys.argv[1:]))", *arguments],
    env=dict(os.environ, TMPDIR=str(temporary)), capture_output=True, text=True, timeout=30,
)
assert result.returncode == 0, result
assert json.loads(result.stdout) == arguments, result.stdout
assert not sentinel.exists(), "GNU sem evaluated command data"
assert not list(temporary.glob("gate-slot-marker-*"))
PY
    [[ "$status" -eq 0 ]]
}

@test "stderr backpressure preserves output and does not block cancellation" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import os
import pathlib
import select
import signal
import subprocess
import sys
import time

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
payload = bytes(range(256)) * 8192
for stop in (None, signal.SIGKILL, signal.SIGTERM):
    pidfile = root / f"blocked-{stop}.pid"
    helper = (
        "import os,pathlib,sys; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); "
        "data=bytes(range(256))*8192; "
        "exec('while data:\\n count=os.write(2,data)\\n data=data[count:]')"
    )
    read_fd, write_fd = os.pipe()
    wrapper = subprocess.Popen(
        [gate, "run", "--slots", "1", "--name", str(pidfile), "--", sys.executable, "-c", helper, str(pidfile)],
        env=dict(os.environ, TMPDIR=str(root)), stdout=subprocess.DEVNULL, stderr=write_fd,
    )
    child = None
    try:
        deadline = time.monotonic() + 30
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert pidfile.exists(), "workload did not start"
        child = int(pidfile.read_text())
        assert select.select([read_fd], [], [], 30)[0], "stderr did not reach the sink"
        assert os.get_blocking(write_fd), "relay changes caller-owned descriptor flags"
        if stop is None:
            received = bytearray()
            while len(received) < len(payload):
                assert select.select([read_fd], [], [], 30)[0], "ordered output stalls"
                received.extend(os.read(read_fd, 8192))
            assert wrapper.wait(timeout=30) == 0
            assert received == payload, "relay drops or reorders bytes"
        else:
            # The unread pipe remains open through the complete cleanup check.
            wrapper.send_signal(stop)
            wrapper.wait(timeout=5)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.02)
            else:
                raise AssertionError("blocked stderr leaves a workload after cancellation")
    finally:
        if wrapper.poll() is None:
            wrapper.kill()
            wrapper.wait()
        if child:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.close(read_fd)
        os.close(write_fd)
PY
    [[ "$status" -eq 0 ]]
}

@test "AC-4 cancels a real queued waiter and reuses both slots in the same pool" {
    run python3 - "$GATE_SLOT" "$TMPROOT" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

gate, root = sys.argv[1], pathlib.Path(sys.argv[2])
name = "gate-slot-real-" + root.name
processes = []
releases = []
def wait_for(predicate):
    deadline = time.monotonic() + 30
    while not predicate():
        assert time.monotonic() < deadline, "startup handshake expires"
        time.sleep(0.02)
holder_code = (
    "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('ready'); "
    "release=pathlib.Path(sys.argv[2]); "
    "exec('while not release.exists(): time.sleep(0.01)')"
)
with (root / "output").open("wb") as output:
    def start(label, command):
        temporary = root / label
        temporary.mkdir()
        process = subprocess.Popen(
            [gate, "run", "--slots", "2", "--name", name, "--", *command],
            env=dict(os.environ, TMPDIR=str(temporary)), stdout=output, stderr=output,
        )
        processes.append(process)
        return process, temporary
    def occupy(label):
        release = root / (label + ".release")
        releases.append(release)
        markers = [root / f"{label}-{index}.ready" for index in range(2)]
        holders = [start(f"{label}-{index}", [sys.executable, "-c", holder_code, str(marker), str(release)])[0]
                   for index, marker in enumerate(markers)]
        wait_for(lambda: all(marker.exists() for marker in markers))
        assert all(process.poll() is None for process in holders)
        return holders, release
    try:
        holders, release = occupy("holders")
        ran = root / "cancelled-ran"
        waiter, temporary = start("waiter", [sys.executable, "-c",
            "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()", str(ran)])
        def queued():
            markers = list(temporary.glob("gate-slot-marker-*/sem"))
            if not markers or not markers[0].read_text():
                return False
            command = subprocess.run(
                ["ps", "-p", markers[0].read_text(), "-o", "command="],
                capture_output=True, text=True, check=False,
            ).stdout
            return "sem " in command and "released=os.read" not in command
        wait_for(queued)
        assert not ran.exists()
        assert all(process.poll() is None for process in holders)
        cancellation_started = time.monotonic()
        waiter.send_signal(signal.SIGTERM)
        assert waiter.wait(timeout=5) != 0
        cancellation_elapsed = time.monotonic() - cancellation_started
        assert cancellation_elapsed <= 1.5, f"Queued cancellation takes {cancellation_elapsed:.3f}s"
        assert not ran.exists()
        release.touch()
        for process in holders:
            assert process.wait(timeout=30) == 0
        probes, probe_release = occupy("probes")
        assert not ran.exists(), "cancelled waiter executes after holders release"
        probe_release.touch()
        for process in probes:
            assert process.wait(timeout=30) == 0
    finally:
        for release in releases:
            release.touch()
        for process in processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
PY
    [[ "$status" -eq 0 ]]
}
