#!/usr/bin/env bats
# Tests for bin/tmux-size-owner

load test_helper

SOCK="bats-size-owner-$$"

setup() {
    setup_test_env
}

teardown() {
    tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
    teardown_test_env
}

# Fail the test with a message, instead of a silent skip, when a step that
# should always succeed on a supported platform does not.
fail() {
    echo "$1" >&2
    return 1
}

require_pty_support() {
    command -v script >/dev/null 2>&1 || skip "script(1) not available"
    script -qfec true /dev/null >/dev/null 2>&1 || skip "script -qfec unsupported on this platform"
}

# Spawn a pty-backed tmux client at the given size, attached to $3 (default
# session "s"). Blocks until it shows up in `list-clients`. Prints the
# client's tty on success. `script` forwards the EOF from /dev/null as ^D to
# the pane, so every test session runs `sleep 300` instead of a shell that
# would exit and take the server down.
spawn_client() {
    local cols="$1" rows="$2" session="${3:-s}"
    local before after new_tty
    before="$(tmux -L "$SOCK" list-clients -F '#{client_tty}' 2>/dev/null)"
    (script -qfec "stty cols $cols rows $rows; TERM=xterm tmux -L $SOCK attach -t $session" /dev/null </dev/null >/dev/null 2>&1 &)

    local waited=0
    while (( waited < 100 )); do
        after="$(tmux -L "$SOCK" list-clients -F '#{client_tty}' 2>/dev/null)"
        new_tty="$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | head -1)"
        [[ -n "$new_tty" ]] && { printf '%s' "$new_tty"; return 0; }
        sleep 0.1
        ((++waited))
    done
    echo "spawn_client timeout; before=[$before] after=[$after]" >&2
    tmux -L "$SOCK" list-clients -F '#{client_tty} #{client_flags}' >&2 || true
    return 1
}

client_flags() {
    tmux -L "$SOCK" list-clients -F '#{client_tty} #{client_flags}' | awk -v t="$1" '$1==t{ $1=""; print substr($0,2) }'
}

# Polls until $1 carries ($2 = flag) or lacks ($2 = !flag) the named flag.
wait_for_flag() {
    local tty="$1" want="$2" waited=0
    while (( waited < 100 )); do
        if [[ "$want" == !* ]]; then
            [[ "$(client_flags "$tty")" != *"${want#!}"* ]] && return 0
        else
            [[ "$(client_flags "$tty")" == *"$want"* ]] && return 0
        fi
        sleep 0.1
        ((++waited))
    done
    fail "client $tty never reached flag state $want"
}

wait_for_client_gone() {
    local waited=0
    while tmux -L "$SOCK" list-clients -F '#{client_tty}' | grep -qx "$1" && (( waited < 100 )); do
        sleep 0.1
        ((++waited))
    done
}

# Points the unqualified `tmux` that tmux-size-owner calls at this isolated
# test server, the way the real client-attached hook/binding do inside a
# live session.
export_test_tmux() {
    local sock_path
    sock_path="$(tmux -L "$SOCK" display -p '#{socket_path}')"
    export TMUX="${sock_path},0,0"
}

@test "missing argument exits 2 with usage" {
    run tmux-size-owner
    [[ "$status" -eq 2 ]]
    [[ "$output" == *"usage: tmux-size-owner <client_tty>"* ]]
}

@test "tmux.conf wires client-attached and client-detached hooks to tmux-size-owner" {
    grep -qE 'set-hook -g client-attached .*tmux-size-owner #\{client_tty\}' \
        "$REAL_DOTFILES_DIR/tmux.conf"
    grep -qE 'set-hook -g client-detached .*tmux-size-owner --release #\{client_session\}' \
        "$REAL_DOTFILES_DIR/tmux.conf"
}

@test "the newest attached client owns the size, and ownership transfers on request" {
    require_pty_support

    tmux -L "$SOCK" -f /dev/null new -d -s s -x 155 -y 47 "sleep 300"
    tmux -L "$SOCK" set -g window-size latest
    export_test_tmux

    local phone_tty big_tty
    phone_tty="$(spawn_client 46 36)" || fail "phone pty client did not attach in time"
    big_tty="$(spawn_client 155 47)" || fail "big pty client did not attach in time"

    run tmux-size-owner "$phone_tty"
    [[ "$status" -eq 0 ]]
    [[ "$(client_flags "$phone_tty")" != *ignore-size* ]]
    [[ "$(client_flags "$big_tty")" == *ignore-size* ]]
    [[ "$(tmux -L "$SOCK" display -p '#{window_width}x#{window_height}')" == "46x35" ]]

    run tmux-size-owner "$big_tty"
    [[ "$status" -eq 0 ]]
    [[ "$(client_flags "$big_tty")" != *ignore-size* ]]
    [[ "$(client_flags "$phone_tty")" == *ignore-size* ]]
    [[ "$(tmux -L "$SOCK" display -p '#{window_width}x#{window_height}')" == "155x46" ]]
}

@test "empty client tty exits 1 and leaves flags untouched" {
    require_pty_support

    tmux -L "$SOCK" -f /dev/null new -d -s s -x 80 -y 24 "sleep 300"
    export_test_tmux

    local tty
    tty="$(spawn_client 80 24)" || fail "pty client did not attach in time"

    run tmux-size-owner ""
    [[ "$status" -eq 1 ]]
    [[ "$(client_flags "$tty")" != *ignore-size* ]]
}

@test "unknown client tty exits 1 and leaves flags untouched" {
    require_pty_support

    tmux -L "$SOCK" -f /dev/null new -d -s s -x 80 -y 24 "sleep 300"
    export_test_tmux

    local tty
    tty="$(spawn_client 80 24)" || fail "pty client did not attach in time"

    run tmux-size-owner "/dev/pts/does-not-exist"
    [[ "$status" -eq 1 ]]
    [[ "$(client_flags "$tty")" != *ignore-size* ]]
}

@test "an owner's flags never touch a client of another session" {
    require_pty_support

    tmux -L "$SOCK" -f /dev/null new -d -s s -x 155 -y 47 "sleep 300"
    tmux -L "$SOCK" new -d -s s2 -x 80 -y 24 "sleep 300"
    tmux -L "$SOCK" set -g window-size latest
    export_test_tmux

    local owner_tty other_tty s2_tty
    owner_tty="$(spawn_client 46 36 s)" || fail "owner pty client did not attach in time"
    other_tty="$(spawn_client 155 47 s)" || fail "other pty client did not attach in time"
    s2_tty="$(spawn_client 80 24 s2)" || fail "s2 pty client did not attach in time"

    run tmux-size-owner "$owner_tty"
    [[ "$status" -eq 0 ]]
    [[ "$(client_flags "$owner_tty")" != *ignore-size* ]]
    [[ "$(client_flags "$other_tty")" == *ignore-size* ]]
    [[ "$(client_flags "$s2_tty")" != *ignore-size* ]]
}

@test "detaching a client hands ownership to the newest survivor of the session" {
    require_pty_support

    tmux -L "$SOCK" -f /dev/null new -d -s s -x 155 -y 47 "sleep 300"
    tmux -L "$SOCK" set -g window-size latest
    tmux -L "$SOCK" set-hook -g client-attached \
        "if -F \"#{!=:#{client_tty},}\" { run-shell -b \"$REAL_DOTFILES_DIR/bin/tmux-size-owner #{client_tty}\" }"
    tmux -L "$SOCK" set-hook -g client-detached \
        "run-shell -b \"$REAL_DOTFILES_DIR/bin/tmux-size-owner --release #{client_session}\""

    # client_activity has one-second resolution; space the attaches so the
    # "newest" ordering is unambiguous.
    local phone_tty mid_tty big_tty
    phone_tty="$(spawn_client 46 36)" || fail "phone pty client did not attach in time"
    sleep 1.1
    mid_tty="$(spawn_client 100 30)" || fail "mid pty client did not attach in time"
    sleep 1.1
    big_tty="$(spawn_client 155 47)" || fail "big pty client did not attach in time"

    wait_for_flag "$mid_tty" ignore-size
    [[ "$(client_flags "$phone_tty")" == *ignore-size* ]]
    [[ "$(client_flags "$big_tty")" != *ignore-size* ]]

    # A non-owner leaving must not disturb the owner.
    tmux -L "$SOCK" detach-client -t "$mid_tty"
    wait_for_client_gone "$mid_tty"
    sleep 0.5
    [[ "$(client_flags "$phone_tty")" == *ignore-size* ]]
    [[ "$(client_flags "$big_tty")" != *ignore-size* ]]
    [[ "$(tmux -L "$SOCK" display -p '#{window_width}x#{window_height}')" == "155x46" ]]

    # The owner leaving hands the size to the survivor.
    tmux -L "$SOCK" detach-client -t "$big_tty"
    wait_for_flag "$phone_tty" '!ignore-size'
    [[ "$(client_flags "$phone_tty")" != *ignore-size* ]]
    [[ "$(tmux -L "$SOCK" display -p '#{window_width}x#{window_height}')" == "46x35" ]]
}
