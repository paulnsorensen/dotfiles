#!/bin/bash
# install-base-profile.sh — compile and apply the live agent profile.
#
# This is the single deploy path that replaces live `ap install`: render a
# scratch chezmoi baseline, fetch external sources, compile `profiles/live`,
# enforce the drift gate, then apply the compiled manifest.
#
# Usage:
#   install-base-profile.sh <target_home> [--accept-agent-drift]
#
# Honors:
#   INSTALL_BASE_PROFILE_AP   path to the `ap` binary (default: `ap` on PATH)
set -euo pipefail

target="${1:-}"
if [[ -z "$target" ]]; then
    echo "Usage: install-base-profile.sh <target_home> [--accept-agent-drift]" >&2
    exit 2
fi
shift

ap_bin="${INSTALL_BASE_PROFILE_AP:-ap}"
if ! command -v "$ap_bin" &>/dev/null && [[ ! -x "$ap_bin" ]]; then
    echo "install-base-profile: ap binary not found ('$ap_bin')" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=chezmoi/lib/agent-profile-sync.sh
source "$SCRIPT_DIR/agent-profile-sync.sh"

if [[ -z "${AGENT_PROFILE_CHEZMOI:-}" ]]; then
    state_file="$(mktemp "${TMPDIR:-/tmp}/ap-chezmoi-state-XXXXXX")"
    chezmoi_wrapper="$(mktemp "${TMPDIR:-/tmp}/ap-chezmoi-XXXXXX")"
    cat > "$chezmoi_wrapper" <<SH
#!/bin/bash
exec chezmoi --persistent-state "$state_file" "\$@" --exclude=scripts
SH
    chmod +x "$chezmoi_wrapper"
    trap 'rm -f "$state_file" "$chezmoi_wrapper"' EXIT
    export AGENT_PROFILE_CHEZMOI="$chezmoi_wrapper"
fi

export AGENT_PROFILE_AP="$ap_bin"
HOME="$target" agent_profile_sync live "$@"
