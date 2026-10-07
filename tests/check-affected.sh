#!/usr/bin/env bash
# Pre-push gate. Runs only the legs and test files that the change affects.
# Run via: just check [--all] [--base REF] [--plan]
# tests/lib/affected.py owns the selection; this script parses options and
# dispatches the selected legs through GNU parallel.
set -euo pipefail

ROOT="$(cd "${0%/*}/.." && pwd)"
cd "$ROOT"

usage() {
    cat <<'EOF'
Usage: just check [--all] [--base REF] [--plan]

  --all       Run every lint and test leg in full (same as `just check-all`).
  --base REF  Compare against the merge base with REF (default: origin/main,
              then main; the CHECK_BASE environment variable also sets REF).
  --plan      Print the selected legs and files, then exit without running.
EOF
}

select_args=()
plan_only=false
while (($#)); do
    case $1 in
        --all) select_args+=(--all); shift ;;
        --base)
            [[ $# -ge 2 ]] || { echo "check: --base needs a REF" >&2; exit 2; }
            select_args+=(--base "$2"); shift 2 ;;
        --plan) plan_only=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$plan_only" == true ]]; then
    exec python3 tests/lib/affected.py plan ${select_args[@]+"${select_args[@]}"}
fi

commands="$(python3 tests/lib/affected.py commands ${select_args[@]+"${select_args[@]}"})"
if [[ -z "$commands" ]]; then
    echo "check: no changes; nothing to run"
    exit 0
fi

joblog="$(mktemp "${TMPDIR:-/tmp}/check-joblog.XXXXXX")"
trap 'rm -f "$joblog"' EXIT

# GNU parallel exports XDG_CACHE_HOME to its jobs even when it is unset in
# the parent, and an empty value makes mise resolve its cache dir to a
# *relative* `mise`, dumping aqua bin_paths caches into the repo root. Pin
# a real value so the shimmed tools every leg runs cache under $HOME.
# --jobs 0 starts every leg at once; the slowest leg is listed first.
rc=0
XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}" parallel --will-cite --jobs 0 -k --group \
    --joblog "$joblog" :::: <(printf '%s\n' "$commands") || rc=$?

# Joblog columns: Seq Host Starttime JobRuntime Send Receive Exitval Signal Command.
echo
awk -F'\t' 'NR > 1 {
    split($9, cmd, " ")
    printf "check: %-14s %s %6.1fs\n", cmd[2], ($7 == 0 && $8 == 0 ? "ok  " : "FAIL"), $4
}' "$joblog"
exit "$rc"
