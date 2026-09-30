#!/usr/bin/env bats
# Unit tests for packages/lib-t3-service.sh
#
# The T3 service runs its own runtime copy, not the mise-installed CLI.
# sync_t3_service must move that runtime to the manifest pin, then repair
# the service state that `t3 update` leaves behind on a protocol change.

load test_helper
bats_require_minimum_version 1.5.0

LIB="$REAL_DOTFILES_DIR/packages/lib-t3-service.sh"

# shellcheck disable=SC2329  # log_* stubs run inside the sourced lib.
setup() {
    setup_test_env
    log_info() { echo "INFO $1"; }
    log_success() { echo "OK $1"; }
    log_warning() { echo "WARN $1" >&2; }
    # shellcheck disable=SC1090
    source "$LIB"

    export T3CODE_HOME="$TEST_HOME/.t3"
    export CALLS="$TEST_HOME/t3-calls"
    MANIFEST="$TEST_HOME/config.toml"

    # Never touch the real user systemd manager.
    mkdir -p "$TEST_HOME/stubs"
    # shellcheck disable=SC2016  # $CALLS expands inside the stub.
    printf '#!/bin/sh\necho "systemctl $*" >> "$CALLS"\n' > "$TEST_HOME/stubs/systemctl"
    chmod +x "$TEST_HOME/stubs/systemctl"
    export PATH="$TEST_HOME/stubs:$PATH"
}

teardown() {
    teardown_test_env
}

write_manifest() {
    printf '[tools]\n"npm:t3" = "%s"\n"npm:other" = "9.9.9"\n' "$1" > "$MANIFEST"
}

# write_runtime <active_version> <service_status>
# The stub keeps the service status in $T3CODE_HOME/status.
# `update` copies itself to the new version and leaves the state stale, as
# t3 0.0.44 does. `install` marks the service installed.
# UPDATE_EXIT and INSTALL_EXIT force failures.
write_runtime() {
    local dir="$T3CODE_HOME/runtime/versions/$1"
    mkdir -p "$dir"
    printf '{\n  "protocol": 2,\n  "activeVersion": "%s"\n}\n' "$1" \
        > "$T3CODE_HOME/runtime/service-state.json"
    printf '%s\n' "$2" > "$T3CODE_HOME/status"
    cat > "$dir/t3" <<'EOF'
#!/bin/bash
echo "$*" >> "$CALLS"
case "$1 $2" in
"service status")
    echo "T3 Code service"
    echo "  Status: $(cat "$T3CODE_HOME/status") · t3@x"
    ;;
"service install")
    [[ -n "${INSTALL_EXIT:-}" ]] && exit "$INSTALL_EXIT"
    echo installed > "$T3CODE_HOME/status"
    ;;
update*)
    [[ -n "${UPDATE_EXIT:-}" ]] && exit "$UPDATE_EXIT"
    mkdir -p "$T3CODE_HOME/runtime/versions/$2"
    cp "$0" "$T3CODE_HOME/runtime/versions/$2/t3"
    echo "needs an update or repair" > "$T3CODE_HOME/status"
    ;;
esac
EOF
    chmod +x "$dir/t3"
}

@test "t3_pinned_version reads only the npm:t3 pin" {
    write_manifest 0.0.44
    run t3_pinned_version "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$output" = "0.0.44" ]
}

@test "sync_t3_service updates to the pin and repairs the stale state" {
    write_manifest 0.0.44
    write_runtime 0.0.42 installed
    run sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    grep -qx 'update 0.0.44 --yes' "$CALLS"
    grep -qx 'systemctl --user reset-failed t3code.service' "$CALLS"
    grep -qx 'service install' "$CALLS"
    [ "$(cat "$T3CODE_HOME/status")" = installed ]
    [[ "$output" == *"OK t3 service updated to 0.0.44"* ]]
}

@test "sync_t3_service does nothing when a healthy service matches the pin" {
    write_manifest 0.0.42
    write_runtime 0.0.42 installed
    run sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^update\|^service install' "$CALLS")" -eq 0 ]
    [[ "$output" == *"already at 0.0.42"* ]]
}

@test "sync_t3_service repairs a service left broken by an earlier update" {
    write_manifest 0.0.44
    write_runtime 0.0.44 "needs an update or repair"
    run sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^update' "$CALLS")" -eq 0 ]
    grep -qx 'service install' "$CALLS"
    [[ "$output" == *"already at 0.0.44"* ]]
}

@test "sync_t3_service never downgrades a newer service" {
    write_manifest 0.0.42
    write_runtime 0.0.44 installed
    run sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^update' "$CALLS")" -eq 0 ]
    [[ "$output" == *"newer than pin 0.0.42"* ]]
}

@test "sync_t3_service skips when no service is installed" {
    write_manifest 0.0.44
    write_runtime 0.0.42 "not installed"
    run sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$(grep -c '^update\|^service install' "$CALLS")" -eq 0 ]
}

@test "sync_t3_service skips when T3 has no runtime state" {
    write_manifest 0.0.44
    run sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ ! -e "$CALLS" ]
}

@test "sync_t3_service warns and continues when the update fails" {
    write_manifest 0.0.44
    write_runtime 0.0.42 installed
    UPDATE_EXIT=1 run --separate-stderr sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"WARN t3 update 0.0.44 failed"* ]]
}

@test "sync_t3_service warns when the repair cannot fix the service" {
    write_manifest 0.0.44
    write_runtime 0.0.42 installed
    INSTALL_EXIT=1 run --separate-stderr sync_t3_service "$MANIFEST"
    [ "$status" -eq 0 ]
    [ "$(grep -cx 'service install' "$CALLS")" -eq 2 ]
    [[ "$stderr" == *"WARN t3 0.0.44 installed but the service is unhealthy"* ]]
}
