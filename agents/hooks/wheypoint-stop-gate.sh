#!/usr/bin/env bash
# Stop hook for Claude and Codex. The shared library owns the policy.
set -u
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
library="$script_dir/../lib/wheypoint-stop-gate.sh"
[[ -f "$library" ]] || exit 0
# shellcheck source=../lib/wheypoint-stop-gate.sh
source "$library"
wheypoint_stop_gate_main
