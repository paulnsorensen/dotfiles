# shellcheck shell=bash
# devbox-keepalive.sh — decide from /proc CPU ticks whether an agent CLI is
# busy, and report activity to the Cloud Workstations idle detector.
#
# The devbox image suspends a workstation after an idle timeout. Its idle
# detector counts only activity that a process reports to
# localhost:981/_workstation/reportactivity. A per-harness hook can send that
# report, but one hook covers one harness and `dots sync` rewrites the hooks
# key on every run. This library watches processes instead: an agent tree
# that burns CPU ticks between two snapshots is busy, and one report keeps
# the box awake. No harness settings file is involved.
#
# Snapshot format: one `<pid>\t<comm>\t<ticks>` line per agent process owned
# by the current uid, sorted by pid. `ticks` is utime+stime summed over the
# agent and every descendant.
#
# Environment (each has a default; tests override them):
#   DEVBOX_KEEPALIVE_PROC       proc root (default /proc)
#   DEVBOX_KEEPALIVE_AGENTS     space-separated comm list
#   DEVBOX_KEEPALIVE_UID        owner uid (default `id -u`)
#   DEVBOX_KEEPALIVE_THRESHOLD  busy when a tree advances by this many ticks (50)
#   DEVBOX_KEEPALIVE_URL        activity endpoint
#   DEVBOX_KEEPALIVE_LOG_MAX    trim the log above this many lines (300)
#
# Functions only — no top-level side effects, so sourcing is safe. Every
# function is `set -e` safe. Written for bash 3.2 (macOS /bin/bash): no
# associative arrays, no mapfile. The proc scan itself is Linux-only.

# dk_proc_rows — print <pid>\t<ppid>\t<ticks>\t<comm> for every process under
# the proc root. The `read` builtin reads each stat line, so a process that
# exits mid-scan is skipped without a fork and without an awk open error
# (gawk aborts on a missing input file). The comm sits between the first "("
# and the last ")" and can hold spaces and parens. After that paren, field 2
# is ppid and fields 12 and 13 are utime and stime (stat fields 4, 14, 15).
dk_proc_rows() {
    local root="${DEVBOX_KEEPALIVE_PROC:-/proc}" f line
    for f in "$root"/[0-9]*/stat; do
        line=""
        IFS= read -r line < "$f" || [[ -n "$line" ]] || continue
        printf '%s\n' "$line"
    done 2>/dev/null | awk '
        {
            open = index($0, "(")
            if (open == 0) next
            last = 0; off = 0; rest = $0
            while ((i = index(rest, ")")) > 0) {
                off += i; last = off; rest = substr(rest, i + 1)
            }
            if (last <= open) next
            n = split(substr($0, last + 2), f, " ")
            if (n < 13) next
            printf "%s\t%s\t%d\t%s\n", substr($0, 1, open - 2), f[2], f[12] + f[13], substr($0, open + 1, last - open - 1)
        }
    '
}

# dk_proc_uid <pid> — print the real uid from <proc>/<pid>/status; fail when
# the process is gone.
dk_proc_uid() {
    local root="${DEVBOX_KEEPALIVE_PROC:-/proc}" key val _
    while read -r key val _; do
        [[ "$key" == "Uid:" ]] || continue
        printf '%s\n' "$val"
        return 0
    done 2>/dev/null < "$root/$1/status"
    return 1
}

# dk_agent_pids — read dk_proc_rows lines on stdin and print the pid of each
# process whose comm is in the agent list and whose real uid is ours. The
# kernel truncates comm to 15 bytes, and a CLI that runs under node reports
# `node`; extend DEVBOX_KEEPALIVE_AGENTS for such a CLI.
dk_agent_pids() {
    local agents="${DEVBOX_KEEPALIVE_AGENTS:-claude codex omp pi cursor-agent opencode gemini copilot}"
    local uid="${DEVBOX_KEEPALIVE_UID:-$(id -u)}"
    local pid comm name _
    while IFS=$'\t' read -r pid _ _ comm; do
        for name in $agents; do
            [[ "$comm" == "$name" ]] || continue
            [[ "$(dk_proc_uid "$pid")" == "$uid" ]] || break
            printf '%s\n' "$pid"
            break
        done
    done
}

# dk_tree_ticks <pid>... — read dk_proc_rows lines on stdin and print
# <pid>\t<comm>\t<ticks> for each named pid, with ticks summed over the pid
# and all of its descendants. Descendants are not uid-filtered: a child that
# runs under sudo still does the agent's work. Sorted by pid so two snapshots
# compare line by line.
dk_tree_ticks() {
    awk -F '\t' -v roots="$*" '
        BEGIN { n = split(roots, root, " ") }
        NF >= 4 {
            seen[$1] = 1; parent[$1] = $2; ticks[$1] = $3
            name = $4
            for (k = 5; k <= NF; k++) name = name "\t" $k
            comm[$1] = name
        }
        END {
            for (i = 1; i <= n; i++) {
                r = root[i]
                if (!(r in seen)) continue
                total = 0
                for (p in seen) {
                    q = p; hops = 0
                    while (hops++ < 256) {
                        if (q == r) { total += ticks[p]; break }
                        if (!(q in parent) || parent[q] == q) break
                        q = parent[q]
                    }
                }
                printf "%s\t%s\t%d\n", r, comm[r], total
            }
        }
    ' | sort -n
}

# dk_snapshot — print the current snapshot: one line per agent process owned
# by the current uid, with its tree ticks. Empty when no agent runs.
dk_snapshot() {
    local rows agents
    rows=$(dk_proc_rows)
    [[ -n "$rows" ]] || return 0
    agents=$(printf '%s\n' "$rows" | dk_agent_pids)
    [[ -n "$agents" ]] || return 0
    # shellcheck disable=SC2086 # one word per pid
    printf '%s\n' "$rows" | dk_tree_ticks $agents
}

# dk_busy <previous snapshot> <current snapshot> — print one reason and
# return 0 when an agent is new or when its tree advanced by at least the
# threshold; return 1 (idle) otherwise. A tree whose ticks went down is a
# reused pid, so it counts as new. An agent that waits for input or for a
# permission answer burns no ticks and reads as idle: that is the intent,
# the box may then suspend.
dk_busy() {
    local threshold="${DEVBOX_KEEPALIVE_THRESHOLD:-50}"
    printf '%s\n@current@\n%s\n' "$1" "$2" | awk -F '\t' -v threshold="$threshold" '
        $0 == "@current@" { current = 1; next }
        NF < 3 { next }
        !current { prev[$1 "\t" $2] = $3; next }
        {
            key = $1 "\t" $2
            if (!(key in prev) || $3 < prev[key]) {
                printf "new %s[%s]\n", $2, $1; busy = 1; exit
            }
            if ($3 - prev[key] >= threshold) {
                printf "%s[%s] +%d ticks\n", $2, $1, $3 - prev[key]; busy = 1; exit
            }
        }
        END { exit !busy }
    '
}

# dk_report — send one activity report and return the curl exit status. -f
# turns an HTTP error into status 22; -m 5 bounds a hung endpoint. The caller
# tolerates a failure: the endpoint can come up late after a boot.
dk_report() {
    curl -fs -m 5 -o /dev/null "${DEVBOX_KEEPALIVE_URL:-http://localhost:981/_workstation/reportactivity}"
}

# dk_save_snapshot <file> <snapshot> — replace the state file atomically.
dk_save_snapshot() {
    printf '%s\n' "$2" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

# dk_once <state file> — compare the saved snapshot with a fresh one, save
# the fresh one, and report when busy. Prints `busy <reason> curl=<status>`
# or `idle`. Returns the curl status after a report, else 0.
dk_once() {
    local state="$1" prev="" cur reason rc=0
    if [[ -f "$state" ]]; then
        prev=$(<"$state")
    fi
    cur=$(dk_snapshot)
    dk_save_snapshot "$state" "$cur" || return 1
    if reason=$(dk_busy "$prev" "$cur"); then
        dk_report || rc=$?
        printf 'busy %s curl=%d\n' "$reason" "$rc"
        return "$rc"
    fi
    printf 'idle\n'
}

# dk_log <log> <message> — append a UTC-stamped line, then keep the file
# short.
dk_log() {
    local log="$1"
    case "$log" in */*) mkdir -p "${log%/*}" || return 1 ;; esac
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$log" || return 1
    dk_log_trim "$log"
}

# dk_log_trim <log> — when the log exceeds DEVBOX_KEEPALIVE_LOG_MAX lines,
# keep the newest half.
dk_log_trim() {
    local log="$1" max="${DEVBOX_KEEPALIVE_LOG_MAX:-300}" lines
    lines=$(wc -l < "$log") || return 1
    (( lines > max )) || return 0
    tail -n "$((max / 2))" "$log" > "$log.tmp" && mv -f "$log.tmp" "$log"
}

# dk_tick <state> <log> — one daemon step: run dk_once and log a busy
# result, report failures included. Never fails, so the loop survives a
# gone endpoint or a vanished process.
dk_tick() {
    local out
    out=$(dk_once "$1" 2>&1) || true
    case "$out" in
        busy*) dk_log "$2" "$out" || true ;;
    esac
    return 0
}

# dk_runtime_dir <dir> — create the private runtime directory. Refuse a
# symlink or a directory owned by another user: /tmp is shared.
dk_runtime_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        (umask 077 && mkdir -p "$dir") || return 1
    fi
    if [[ -L "$dir" || ! -O "$dir" ]]; then
        echo "devbox-keepalive: refusing $dir: not a directory owned by $(id -un)" >&2
        return 1
    fi
}

# dk_daemon <runtime dir> <state> <log> <interval> — hold the singleton lock
# on <runtime dir>/daemon.lock, then run dk_tick every <interval> seconds
# until SIGTERM. A second instance prints the holder's pid and returns 0, so
# a repeated boot hook is harmless. The lock file carries the holder's pid
# for dk_status; the flock, not the pid, is the truth.
dk_daemon() {
    local dir="$1" state="$2" log="$3" interval="$4" lock="$1/daemon.lock" holder="" sleeper=""
    dk_runtime_dir "$dir" || return 1
    exec 9>>"$lock"
    if ! flock -n 9; then
        read -r holder < "$lock" || true
        echo "devbox-keepalive: daemon already running (pid ${holder:-unknown})" >&2
        return 0
    fi
    printf '%s\n' "$$" > "$lock"
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
    while :; do
        dk_tick "$state" "$log"
        sleep "$interval" &
        sleeper=$!
        wait "$sleeper" || true
    done
}

# dk_status <lock> <log> — print whether a daemon holds the lock, and the
# last accepted report line.
dk_status() {
    local lock="$1" log="$2" pid="" last=""
    if [[ -f "$lock" ]] && ! flock -n "$lock" true 2>/dev/null; then
        read -r pid < "$lock" || true
        printf 'running pid=%s\n' "${pid:-unknown}"
    else
        printf 'stopped\n'
    fi
    if [[ -f "$log" ]]; then
        last=$(grep ' curl=0$' "$log" | tail -n 1) || true
    fi
    if [[ -n "$last" ]]; then
        printf 'last report %s\n' "$last"
    else
        printf 'last report none\n'
    fi
}
