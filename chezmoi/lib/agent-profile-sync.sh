#!/usr/bin/env bash
# Sourceable orchestration helpers for compiled agent-profile sync.

agent_profile_sync() {
    local profile accept_drift cache_dir baseline_dir manifest

    profile=${1:-}
    if [[ -z "$profile" ]]; then
        echo "Usage: agent_profile_sync <profile> [--accept-agent-drift]" >&2
        return 2
    fi
    shift

    accept_drift=false
    while (($#)); do
        case "$1" in
            --accept-agent-drift)
                accept_drift=true
                shift
                ;;
            *)
                echo "agent-profile-sync: unknown option '$1'" >&2
                return 2
                ;;
        esac
    done

    cache_dir=$(agent_profile_cache_dir "$profile") || return
    baseline_dir=$(agent_profile_make_baseline_dir) || return

    if ! agent_profile_render_baseline "$baseline_dir"; then
        agent_profile_cleanup "$baseline_dir"
        echo "agent-profile-sync: failed to render chezmoi baseline" >&2
        return 1
    fi

    if ! agent_profile_fetch_sources "$profile"; then
        agent_profile_cleanup "$baseline_dir"
        return 1
    fi

    if ! agent_profile_compile "$profile" "$baseline_dir" "$cache_dir"; then
        agent_profile_cleanup "$baseline_dir"
        return 1
    fi

    if ! agent_profile_drift_gate "$cache_dir" "$accept_drift"; then
        agent_profile_cleanup "$baseline_dir"
        return 1
    fi

    manifest="$cache_dir/manifest.json"
    if ! agent_profile_apply_compiled "$manifest"; then
        agent_profile_cleanup "$baseline_dir"
        return 1
    fi

    agent_profile_cleanup "$baseline_dir"
}

agent_profile_cache_dir() {
    local profile cache_root
    profile=$1
    if [[ -n "${AGENT_PROFILE_CACHE_DIR:-}" ]]; then
        printf '%s\n' "$AGENT_PROFILE_CACHE_DIR"
        return 0
    fi
    cache_root=${XDG_CACHE_HOME:-$HOME/.cache}
    printf '%s\n' "$cache_root/dotfiles/agent-profile/$profile"
}

agent_profile_make_baseline_dir() {
    mkdir -p "${TMPDIR:-/tmp}" || return
    mktemp -d "${TMPDIR:-/tmp}/ap-baseline-XXXXXX"
}

agent_profile_cleanup() {
    local path
    path=${1:-}
    [[ -n "$path" && -d "$path" ]] && rm -rf "$path"
}

agent_profile_ap() {
    local ap_bin
    ap_bin=${AGENT_PROFILE_AP:-ap}
    if ! command -v "$ap_bin" >/dev/null 2>&1 && [[ ! -x "$ap_bin" ]]; then
        echo "agent-profile-sync: ap binary not found ('$ap_bin')" >&2
        return 1
    fi
    "$ap_bin" "$@"
}

agent_profile_chezmoi() {
    local chezmoi_bin
    chezmoi_bin=${AGENT_PROFILE_CHEZMOI:-chezmoi}
    if ! command -v "$chezmoi_bin" >/dev/null 2>&1 && [[ ! -x "$chezmoi_bin" ]]; then
        echo "agent-profile-sync: chezmoi binary not found ('$chezmoi_bin')" >&2
        return 1
    fi
    "$chezmoi_bin" "$@"
}

agent_profile_render_baseline() {
    local baseline source_dir
    baseline=$1
    source_dir=${AGENT_PROFILE_CHEZMOI_SOURCE:-${DOTFILES_DIR:-$PWD}/chezmoi}
    agent_profile_chezmoi --source "$source_dir" --destination "$baseline" apply --force
}

agent_profile_fetch_sources() {
    local profile
    profile=$1
    agent_profile_ap fetch-sources "$profile"
}

agent_profile_compile() {
    local profile baseline cache_dir
    profile=$1
    baseline=$2
    cache_dir=$3
    mkdir -p "$cache_dir" || return
    agent_profile_ap compile "$profile" --baseline "$baseline" --out "$cache_dir"
}

agent_profile_apply_compiled() {
    local manifest
    manifest=$1
    agent_profile_ap apply-compiled "$manifest"
}

agent_profile_has_drift() {
    local cache_dir manifest
    cache_dir=$1
    manifest="$cache_dir/manifest.json"
    python3 - "$manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
try:
    data = json.loads(manifest.read_text())
except Exception as exc:
    print(f"agent-profile-sync: cannot read drift records from {manifest}: {exc}", file=sys.stderr)
    sys.exit(2)

drift = data.get("drift", [])
if not isinstance(drift, list):
    print(f"agent-profile-sync: manifest {manifest} has invalid drift records", file=sys.stderr)
    sys.exit(2)
sys.exit(0 if drift else 1)
PY
}

# Print a human-readable summary of the drift between the live install and the
# compiled output, reading the `drift` records from the manifest. Records whose
# `live` and `compiled` values are present and equal are no-ops (the file just
# isn't in the chezmoi scratch baseline) and are omitted; everything else is a
# pending change shown as `live → compiled`. Long/multiline values are
# truncated so the codex/copilot whole-file merge records stay readable.
agent_profile_print_drift_delta() {
    local cache_dir manifest
    cache_dir=$1
    manifest="$cache_dir/manifest.json"
    python3 - "$manifest" <<'PY'
import json
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
try:
    records = json.loads(manifest.read_text()).get("drift", [])
except Exception:
    sys.exit(0)
if not isinstance(records, list):
    sys.exit(0)


def fmt(value, absent):
    if value is None:
        return absent
    text = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
    text = " ".join(text.split())
    return text if len(text) <= 60 else text[:57] + "..."


def is_noop(rec):
    return "live" in rec and "compiled" in rec and rec["live"] == rec["compiled"]


changes = [r for r in records if isinstance(r, dict) and not is_noop(r)]
print("agent-profile-sync: compiled agent config differs from your live install", file=sys.stderr)
if not changes:
    print("    (re-tracking only — no value changes)", file=sys.stderr)
    sys.exit(0)

cap = 50
shown = 0
last_file = None
for rec in changes:
    if shown >= cap:
        break
    rel = rec.get("relative_path") or "(unknown)"
    if rel != last_file:
        print(f"  {rel}", file=sys.stderr)
        last_file = rel
    path = rec.get("path") or "(whole file)"
    if "live" in rec or "compiled" in rec:
        delta = f"{fmt(rec.get('live'), '(none)')} → {fmt(rec.get('compiled'), '(removed)')}"
        print(f"    {path}: {delta}", file=sys.stderr)
    else:
        print(f"    {path}", file=sys.stderr)
    shown += 1

remaining = len(changes) - shown
if remaining > 0:
    print(f"    … and {remaining} more change(s)", file=sys.stderr)
PY
}

agent_profile_drift_gate() {
    local cache_dir accept_drift drift_status
    cache_dir=$1
    accept_drift=$2

    agent_profile_has_drift "$cache_dir"
    drift_status=$?
    case "$drift_status" in
        0) ;;
        1) return 0 ;;
        *) return 1 ;;
    esac

    agent_profile_print_drift_delta "$cache_dir"

    if [[ "$accept_drift" == true ]]; then
        echo "agent-profile-sync: continuing because --accept-agent-drift was passed" >&2
        return 0
    fi

    if ! _apsync_interactive; then
        echo "agent-profile-sync: drift NOT applied during noninteractive dots sync." >&2
        echo "agent-profile-sync: to apply the changes above, re-run: dots sync --accept-agent-drift" >&2
        return 1
    fi

    if _apsync_confirm "Continue and apply the changes above? [y/N] "; then
        return 0
    fi

    echo "agent-profile-sync: drift not accepted; aborting" >&2
    return 1
}

_apsync_interactive() {
    [[ -t 0 && -t 1 ]]
}

_apsync_confirm() {
    local prompt reply
    prompt=$1
    read -r -p "$prompt" reply
    [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    agent_profile_sync "$@"
fi
