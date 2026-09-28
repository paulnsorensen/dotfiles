#!/usr/bin/env bats
# Tests for bin/lib/agent-secret-doctor.sh.
#
# WHY these matter: a broker that outlives its worktree or shares a socket
# with another broker holds a credential-bearing upstream for weeks with no
# signal. `dots doctor` is the only place that surfaces it.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"

setup() {
    T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/asdoctor.XXXXXX")" && pwd)
    LIVE="$T/live/agent-secret-broker.py"
    GONE="$T/gone/agent-secret-broker.py"
    mkdir -p "${LIVE%/*}"
    : > "$LIVE"
    # shellcheck source=bin/lib/agent-secret-doctor.sh
    source "$DOTFILES_DIR/bin/lib/agent-secret-doctor.sh"
}

teardown() {
    rm -rf "$T"
}

@test "healthy brokers on distinct sockets report nothing" {
    run asd_stale_brokers <<EOF
  612 /usr/bin/python3 $LIVE --mode broker --ensure-socket-parent --policy /etc/a.json --socket /run/a.sock --control-socket /run/a.control.sock
  613 /usr/bin/python3 $LIVE --mode broker --ensure-socket-parent --policy /etc/b.json --socket /run/b.sock --control-socket /run/b.control.sock
  700 /usr/bin/python3 $GONE --mode proxy --socket /run/a.sock
EOF
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a broker whose script path is gone is reported" {
    run asd_stale_brokers <<EOF
  25706 /usr/bin/python3 $GONE --mode broker --policy /tmp/p.json --socket /tmp/w/request.sock --control-socket /tmp/w/control.sock
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'missing-script\t25706\t%s' "$GONE")" ]
}

@test "every broker sharing one socket is reported" {
    run asd_stale_brokers <<EOF
  4101 /usr/bin/python3 $LIVE --mode broker --policy /etc/a.json --socket /run/a.sock
  4167 /usr/bin/python3 $LIVE --mode broker --policy /etc/a.json --socket /run/a.sock
  613 /usr/bin/python3 $LIVE --mode broker --policy /etc/b.json --socket /run/b.sock
EOF
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'duplicate-socket\t4101\t/run/a.sock\nduplicate-socket\t4167\t/run/a.sock')" ]
}

@test "brokers without --socket are keyed on their policy" {
    run asd_stale_brokers <<EOF
  1 /usr/bin/python3 $LIVE --mode broker --policy /etc/a.json
  2 /usr/bin/python3 $LIVE --mode broker --policy /etc/b.json
EOF
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no broker processes report nothing" {
    run asd_stale_brokers < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
