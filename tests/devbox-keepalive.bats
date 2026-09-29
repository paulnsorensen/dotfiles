#!/usr/bin/env bats
# Tests for bin/lib/devbox-keepalive.sh and bin/devbox-keepalive.
#
# WHY these matter: the Cloud Workstations idle detector suspends the devbox
# after an idle timeout. The daemon is the only keep-alive path that needs no
# hook in a harness, so a wrong busy/idle call either suspends a working agent
# or keeps a parked box awake for hours.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
    T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dkeep.XXXXXX")" && pwd)
    PROC="$T/proc"
    mkdir -p "$PROC" "$T/bin"
    export DEVBOX_KEEPALIVE_PROC="$PROC"
    export DEVBOX_KEEPALIVE_UID=1000
    export DEVBOX_KEEPALIVE_URL="http://localhost:981/_workstation/reportactivity"
    export DEVBOX_KEEPALIVE_RUNTIME_DIR="$T/run"
    export DEVBOX_KEEPALIVE_STATE_DIR="$T/state"
    unset DEVBOX_KEEPALIVE_AGENTS DEVBOX_KEEPALIVE_THRESHOLD DEVBOX_KEEPALIVE_INTERVAL DEVBOX_KEEPALIVE_LOG_MAX
    export PATH="$T/bin:$DOTFILES_DIR/bin:$PATH"
    # shellcheck source=bin/lib/devbox-keepalive.sh
    source "$DOTFILES_DIR/bin/lib/devbox-keepalive.sh"
}

teardown() {
    rm -rf "$T"
}

# mkproc <pid> <ppid> <comm> <utime> <stime> [uid] — write a <proc>/<pid>/stat
# line with the 52 fields of a 6.x kernel (copied from a live claude process)
# and a status file with the Uid line. Rewriting an existing pid advances it.
mkproc() {
    local pid=$1 ppid=$2 comm=$3 utime=$4 stime=$5 uid=${6:-1000}
    mkdir -p "$PROC/$pid"
    printf '%s (%s) S %s %s %s 34817 %s 4194560 1943036 138508375 12 9484 %s %s 1110955 198047 20 0 19 0 4650187 5739986944 128473 18446744073709551615 26388480 89069872 140720583326064 0 0 0 0 4096 2072145151 0 0 0 17 7 0 0 0 0 0 89073968 245108736 1275555840 140720583333093 140720583333100 140720583333100 140720583335899 0\n' \
        "$pid" "$comm" "$ppid" "$pid" "$ppid" "$pid" "$utime" "$stime" > "$PROC/$pid/stat"
    printf 'Name:\t%s\nUmask:\t0022\nState:\tS (sleeping)\nTgid:\t%s\nNgid:\t0\nPid:\t%s\nPPid:\t%s\nTracerPid:\t0\nUid:\t%s\t%s\t%s\t%s\nGid:\t1000\t1000\t1000\t1000\nThreads:\t19\n' \
        "$comm" "$pid" "$pid" "$ppid" "$uid" "$uid" "$uid" "$uid" > "$PROC/$pid/status"
}

# make_fake_curl [exit code] — a curl on PATH that records its arguments.
make_fake_curl() {
    cat > "$T/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/curl.log"
exit ${1:-0}
SH
    chmod +x "$T/bin/curl"
}

agent_pids() { dk_proc_rows | dk_agent_pids; }
sorted_rows() { dk_proc_rows | sort -n; }

# ── proc parsing ────────────────────────────────────────────────────────

@test "dk_proc_rows parses pid, ppid, ticks, and comm with spaces or parens" {
    mkproc 1 0 systemd 10 5
    mkproc 500 1 "(sd-pam)" 3 4
    mkproc 600 1 "tmux: server" 7 8
    mkproc 700 600 "a) b" 1 1
    run sorted_rows
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '1\t0\t15\tsystemd\n500\t1\t7\t(sd-pam)\n600\t1\t15\ttmux: server\n700\t600\t2\ta) b')" ]
}

@test "dk_proc_rows skips a stat file that is gone or malformed" {
    mkproc 1 0 systemd 10 5
    mkdir -p "$PROC/77"
    printf 'not a stat line\n' > "$PROC/77/stat"
    mkdir -p "$PROC/78"
    run sorted_rows
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '1\t0\t15\tsystemd')" ]
}

@test "dk_proc_rows is empty on an empty proc root" {
    run dk_proc_rows
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "dk_agent_pids keeps agent comms owned by the current uid" {
    mkproc 1 0 systemd 0 0 0
    mkproc 10 1 claude 5 5
    mkproc 11 1 claude 5 5 0
    mkproc 12 1 codex 1 1
    mkproc 13 1 node 9 9
    mkproc 14 1 claudette 1 1
    run agent_pids
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '10\n12')" ]
}

@test "dk_agent_pids honors DEVBOX_KEEPALIVE_AGENTS" {
    mkproc 10 1 claude 5 5
    mkproc 13 1 node 9 9
    export DEVBOX_KEEPALIVE_AGENTS="node"
    run agent_pids
    [ "$status" -eq 0 ]
    [ "$output" = "13" ]
}

# ── tree summation ──────────────────────────────────────────────────────

@test "dk_snapshot sums ticks over each agent tree and skips other processes" {
    mkproc 1 0 systemd 100 100 0
    mkproc 600 1 "tmux: server" 500 500
    mkproc 601 600 zsh 20 20
    mkproc 1670 601 claude 100 20
    mkproc 1700 1670 bash 10 5
    mkproc 1701 1700 rg 3 2
    mkproc 1800 1670 node 1 1 0
    mkproc 2000 601 codex 30 30
    mkproc 2100 601 vim 999 999
    run dk_snapshot
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '1670\tclaude\t142\n2000\tcodex\t60')" ]
}

@test "dk_snapshot is empty when no agent runs" {
    mkproc 1 0 systemd 1 1 0
    mkproc 601 1 zsh 20 20
    run dk_snapshot
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── busy / idle decision ────────────────────────────────────────────────

@test "dk_busy is idle when no tree advances by the threshold" {
    run dk_busy "$(printf '1670\tclaude\t142\n2000\tcodex\t60')" "$(printf '1670\tclaude\t191\n2000\tcodex\t60')"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "dk_busy is busy when a tree advances by at least the threshold" {
    run dk_busy "$(printf '1670\tclaude\t142')" "$(printf '1670\tclaude\t192')"
    [ "$status" -eq 0 ]
    [ "$output" = "claude[1670] +50 ticks" ]
}

@test "dk_busy treats a new agent as busy" {
    run dk_busy "$(printf '1670\tclaude\t142')" "$(printf '1670\tclaude\t142\n2000\tcodex\t0')"
    [ "$status" -eq 0 ]
    [ "$output" = "new codex[2000]" ]
}

@test "dk_busy treats every agent as new against an empty snapshot" {
    run dk_busy "" "$(printf '1670\tclaude\t0')"
    [ "$status" -eq 0 ]
    [ "$output" = "new claude[1670]" ]
}

@test "dk_busy is idle when the agent exited" {
    run dk_busy "$(printf '1670\tclaude\t142')" ""
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "dk_busy treats a reused pid with fewer ticks as new" {
    run dk_busy "$(printf '1670\tclaude\t142')" "$(printf '1670\tclaude\t3')"
    [ "$status" -eq 0 ]
    [ "$output" = "new claude[1670]" ]
}

@test "dk_busy honors DEVBOX_KEEPALIVE_THRESHOLD" {
    run dk_busy "$(printf '1670\tclaude\t100')" "$(printf '1670\tclaude\t130')"
    [ "$status" -eq 1 ]
    export DEVBOX_KEEPALIVE_THRESHOLD=30
    run dk_busy "$(printf '1670\tclaude\t100')" "$(printf '1670\tclaude\t130')"
    [ "$status" -eq 0 ]
    [ "$output" = "claude[1670] +30 ticks" ]
}

# ── report, log, runtime dir ────────────────────────────────────────────

@test "dk_report returns the curl status and bounds the request" {
    make_fake_curl 7
    run dk_report
    [ "$status" -eq 7 ]
    grep -q -- '-m 5' "$T/curl.log"
    grep -q 'localhost:981/_workstation/reportactivity' "$T/curl.log"
}

@test "dk_log_trim keeps the log under the limit" {
    export DEVBOX_KEEPALIVE_LOG_MAX=10
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11; do
        dk_log "$T/state/keepalive.log" "line $i"
    done
    [ "$(wc -l < "$T/state/keepalive.log")" -eq 5 ]
    grep -q 'line 11$' "$T/state/keepalive.log"
    ! grep -q 'line 1$' "$T/state/keepalive.log"
}

@test "dk_runtime_dir creates a private directory" {
    run dk_runtime_dir "$T/run"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$T/run" 2>/dev/null || stat -f %Lp "$T/run")" = "700" ]
}

@test "dk_runtime_dir refuses a symlink" {
    mkdir -p "$T/elsewhere"
    ln -s "$T/elsewhere" "$T/run"
    run dk_runtime_dir "$T/run"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing"* ]]
}

# ── CLI ─────────────────────────────────────────────────────────────────

@test "devbox-keepalive once: a new agent is busy and sends one report" {
    make_fake_curl 0
    mkproc 1 0 systemd 1 1 0
    mkproc 1670 1 claude 100 20
    run devbox-keepalive once
    [ "$status" -eq 0 ]
    [ "$output" = "busy new claude[1670] curl=0" ]
    [ "$(wc -l < "$T/curl.log")" -eq 1 ]
    [ "$(cat "$T/run/once.snapshot")" = "$(printf '1670\tclaude\t120')" ]
}

@test "devbox-keepalive once: a small CPU change is idle and sends nothing" {
    make_fake_curl 0
    mkproc 1670 1 claude 100 20
    devbox-keepalive once >/dev/null
    rm -f "$T/curl.log"
    mkproc 1670 1 claude 110 20
    run devbox-keepalive once
    [ "$status" -eq 0 ]
    [ "$output" = "idle" ]
    [ ! -e "$T/curl.log" ]
}

@test "devbox-keepalive once: a failed report returns the curl status" {
    make_fake_curl 7
    mkproc 1670 1 claude 100 20
    devbox-keepalive once >/dev/null 2>&1 || true
    mkproc 1670 1 claude 200 20
    run devbox-keepalive once
    [ "$status" -eq 7 ]
    [ "$output" = "busy claude[1670] +100 ticks curl=7" ]
}

@test "devbox-keepalive status: stopped with no daemon" {
    run devbox-keepalive status
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "stopped" ]
    [ "${lines[1]}" = "last report none" ]
}

@test "devbox-keepalive daemon: a second instance exits while the lock is held" {
    mkdir -p "$T/run"
    printf '4242\n' > "$T/run/daemon.lock"
    flock "$T/run/daemon.lock" sleep 2 &
    local holder=$! tries=0
    until ! flock -n "$T/run/daemon.lock" true; do
        sleep 0.05
        tries=$((tries + 1))
        [ "$tries" -lt 40 ]
    done
    run devbox-keepalive daemon --interval 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running (pid 4242)"* ]]
    run devbox-keepalive status
    [ "${lines[0]}" = "running pid=4242" ]
    wait "$holder" || true
    run devbox-keepalive status
    [ "${lines[0]}" = "stopped" ]
}

@test "devbox-keepalive daemon: logs one line per report and stops on SIGTERM" {
    command -v timeout >/dev/null 2>&1 || skip "timeout not installed"
    make_fake_curl 0
    mkproc 1670 1 claude 100 20
    run timeout 3 devbox-keepalive daemon --interval 1
    [ "$status" -eq 124 ]
    [ "$(wc -l < "$T/curl.log")" -eq 1 ]
    [ "$(wc -l < "$T/state/keepalive.log")" -eq 1 ]
    grep -q ' busy new claude\[1670\] curl=0$' "$T/state/keepalive.log"
    run devbox-keepalive status
    [ "${lines[0]}" = "stopped" ]
    [[ "${lines[1]}" == "last report "*" busy new claude[1670] curl=0" ]]
}

@test "devbox-keepalive daemon rejects a bad --interval" {
    run devbox-keepalive daemon --interval abc
    [ "$status" -eq 1 ]
    [[ "$output" == *"positive integer"* ]]
}

@test "devbox-keepalive rejects an unknown subcommand" {
    run devbox-keepalive bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *Usage* ]]
}
