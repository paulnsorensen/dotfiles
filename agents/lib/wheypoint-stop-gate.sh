#!/usr/bin/env bash
# Source this library from the self-locating hook entry.
wheypoint_stop_gate_main() {
    [[ "${WHEYPOINT_STOP_GATE:-1}" == 0 ]] && return 0
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 0
    [[ -f "$root/lib/wheypoint-stop-gate.cjs" ]] || return 0
    command -v node >/dev/null 2>&1 || return 0
    node "$root/lib/wheypoint-stop-gate.cjs" || return 0
}
