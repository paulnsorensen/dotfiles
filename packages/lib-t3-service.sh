#!/bin/bash
############################
# packages/lib-t3-service.sh
# Move the T3 Code background service to the pinned `npm:t3` version.
#
# mise installs the `t3` CLI from the manifest pin, but the service does not
# run that CLI. `t3 service install` writes a unit that runs its own runtime
# copy at $T3CODE_HOME/runtime/versions/<version>/t3. A pin bump alone never
# moves a headless server, so `dots sync` calls `t3 update <pin>` here.
#
# `t3 update` does not migrate service-state.json across a protocol change
# (0.0.42 -> 0.0.44 moved protocol 2 -> 3). The new launcher then exits in a
# loop until systemd hits its start limit. `t3 service install` from the new
# version rewrites the state, so sync repairs with it after every update.
#
# Contract: the sourcing script must define log_info/log_success/log_warning.
############################

# Print the `npm:t3` pin from a mise TOML manifest, or nothing.
#   t3_pinned_version <manifest>
t3_pinned_version() {
    sed -n 's/^"npm:t3"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

# Print the service runtime version from service-state.json, or nothing.
#   t3_active_version <t3_home>
t3_active_version() {
    local state="$1/runtime/service-state.json"
    [[ -f "$state" ]] || return 0
    sed -n 's/.*"activeVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$state" | head -n1
}

# Print the service status: installed, needs an update or repair, and so on.
#   t3_service_status <t3_bin>
t3_service_status() {
    "$1" service status 2>/dev/null |
        sed -n 's/^[[:space:]]*Status:[[:space:]]*\([^·]*\).*/\1/p' |
        sed 's/[[:space:]]*$//' | head -n1
}

# Run `t3 service install` until the service reports installed.
# Clear the systemd start limit first: a crash loop blocks the restart.
#   t3_repair_service <t3_home> <t3_bin>
t3_repair_service() {
    local home="$1" bin="$2" unit="${T3_BOOT_SERVICE_UNIT:-t3code.service}" attempt
    for attempt in 1 2; do
        [[ "$(t3_service_status "$bin")" == installed ]] && return 0
        ((attempt == 1)) && log_info "Repairing t3 service state (t3 service install)..."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
        fi
        T3CODE_HOME="$home" "$bin" service install </dev/null >/dev/null 2>&1 || true
    done
    [[ "$(t3_service_status "$bin")" == installed ]]
}

# Update the installed T3 service to the manifest pin, then repair its state.
# Skip when no service is installed or when the service already runs a newer
# version (a manual `t3 update`). A failure only warns.
#   sync_t3_service <manifest>
sync_t3_service() {
    local manifest="$1"
    local home="${T3CODE_HOME:-$HOME/.t3}"
    local pin active bin status

    pin="$(t3_pinned_version "$manifest")"
    [[ -n "$pin" ]] || return 0
    active="$(t3_active_version "$home")"
    [[ -n "$active" ]] || return 0
    bin="$home/runtime/versions/$active/t3"
    [[ -x "$bin" ]] || return 0
    status="$(t3_service_status "$bin")"
    [[ "$status" == installed || "$status" == "needs an update or repair" ]] || return 0

    if [[ "$active" == "$pin" ]]; then
        if t3_repair_service "$home" "$bin"; then
            echo "  + t3 service already at $pin"
        else
            log_warning "t3 service $pin needs repair; run: t3 service install"
        fi
        return 0
    fi
    if [[ "$(printf '%s\n%s\n' "$pin" "$active" | sort -V | tail -n1)" == "$active" ]]; then
        log_info "t3 service runs $active, newer than pin $pin — leaving it"
        return 0
    fi

    log_info "Updating t3 service $active -> $pin..."
    if ! T3CODE_HOME="$home" "$bin" update "$pin" --yes </dev/null; then
        log_warning "t3 update $pin failed; run: t3 update $pin --yes && t3 service install"
        return 0
    fi
    if ! t3_repair_service "$home" "$home/runtime/versions/$pin/t3"; then
        log_warning "t3 $pin installed but the service is unhealthy; run: t3 service install"
        return 0
    fi
    log_success "t3 service updated to $pin"
}
