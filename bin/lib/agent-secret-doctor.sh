# shellcheck shell=bash
# agent-secret-doctor.sh — find agent secret brokers that outlived their
# source or that share one socket.
#
# A broker started from a worktree runs that worktree's copy of
# scripts/agent-secret-broker.py. When the worktree goes away, a broker that
# is still alive runs code that no longer exists on disk. Two brokers on one
# socket mean one of them serves nothing. Both are findings.
#
# asd_stale_brokers reads `ps -axo pid=,command=` lines on stdin and prints
# findings as TSV lines: <category>\t<pid>\t<detail>. Categories:
#   missing-script    the broker's script path does not exist
#   duplicate-socket  another broker process serves the same socket
#
# Functions only — no top-level side effects, so sourcing is safe. Written for
# bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

# asd_broker_rows — print <pid>\t<script>\t<socket key> for each broker-mode
# process on stdin. A broker without --socket keys on its --policy path,
# because the broker derives its default socket from the policy.
asd_broker_rows() {
    awk '
        {
            script = ""; sock = ""; policy = ""; broker = 0
            for (i = 2; i <= NF; i++) {
                if ($i ~ /agent-secret-broker\.py$/) script = $i
                if ($i == "--mode" && $(i + 1) == "broker") broker = 1
                if ($i == "--socket") sock = $(i + 1)
                if ($i == "--policy") policy = $(i + 1)
            }
            if (!broker || script == "") next
            if (sock == "") sock = "policy:" policy
            printf "%s\t%s\t%s\n", $1, script, sock
        }
    '
}

asd_stale_brokers() {
    local rows pid script sock dupes
    rows=$(asd_broker_rows)
    [[ -n "$rows" ]] || return 0
    dupes=$(printf '%s\n' "$rows" | cut -f3 | sort | uniq -d)
    while IFS=$'\t' read -r pid script sock; do
        [[ -e "$script" ]] || printf 'missing-script\t%s\t%s\n' "$pid" "$script"
        if [[ -n "$dupes" ]] && printf '%s\n' "$dupes" | grep -Fxq -- "$sock"; then
            printf 'duplicate-socket\t%s\t%s\n' "$pid" "$sock"
        fi
    done <<< "$rows"
}
