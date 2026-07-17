#!/usr/bin/env bash
# Offline dynamic-workflow smoke suite. Run via: just smoke.
set -euo pipefail

SCRIPT_DIR="$(cd "${0%/*}" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
    if [[ -n "${CI:-}" ]]; then
        echo "node not on PATH — required in CI" >&2
        exit 1
    fi
    echo "node not on PATH — skipping workflow tests"
    exit 0
fi

exec node --test "$REPO_ROOT"/tests/workflows/*.test.mjs
