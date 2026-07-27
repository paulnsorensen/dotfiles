#!/usr/bin/env bash
# Shared cgroup helpers for agent-run and heavy-run.

set -euo pipefail

DEV_HEAVY_SLICE="${DEV_HEAVY_SLICE:-dev-heavy.slice}"
DEV_HEAVY_CGROUP_ROOT="${DEV_HEAVY_CGROUP_ROOT:-/sys/fs/cgroup}"

_dev_heavy_linux() {
    [[ "$(uname -s)" == Linux ]]
}

dev_heavy_require_ready() {
    _dev_heavy_linux || return 0

    command -v systemd-run >/dev/null 2>&1 || {
        echo "agent containment unavailable: systemd-run is missing" >&2
        return 1
    }
    command -v systemctl >/dev/null 2>&1 || {
        echo "agent containment unavailable: systemctl is missing" >&2
        return 1
    }

    systemctl --user start "$DEV_HEAVY_SLICE" >/dev/null 2>&1 || {
        echo "agent containment unavailable: cannot start $DEV_HEAVY_SLICE" >&2
        return 1
    }

    local load_state control_group io_max io_max_content
    load_state=$(systemctl --user show "$DEV_HEAVY_SLICE" -p LoadState --value)
    [[ "$load_state" == loaded ]] || {
        echo "agent containment unavailable: $DEV_HEAVY_SLICE is $load_state" >&2
        return 1
    }

    control_group=$(systemctl --user show "$DEV_HEAVY_SLICE" -p ControlGroup --value)
    [[ -n "$control_group" ]] || {
        echo "agent containment unavailable: $DEV_HEAVY_SLICE has no cgroup" >&2
        return 1
    }

    io_max="$DEV_HEAVY_CGROUP_ROOT$control_group/io.max"
    # cgroup pseudo-files report size zero even when they hold a limit.
    io_max_content=""
    if [[ -r "$io_max" ]]; then
        io_max_content=$(< "$io_max")
    fi
    [[ -n "$io_max_content" ]] || {
        echo "agent containment unavailable: $DEV_HEAVY_SLICE has no io.max ceiling" >&2
        return 1
    }
}

dev_heavy_run_scope() {
    local unit="$1"
    shift
    _dev_heavy_linux || { "$@"; return; }
    DEV_HEAVY_ACTIVE=1 systemd-run --user --quiet --scope --collect \
        --slice="$DEV_HEAVY_SLICE" --unit="$unit" -- "$@"
}
