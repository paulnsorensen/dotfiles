#!/usr/bin/env bash
# Serena MCP smoke test — boots the real stdio server and asserts it:
#   1. starts without a traceback,
#   2. auto-detects a project from cwd,
#   3. applies our chezmoi-managed excluded_tools (8 memory/onboarding tools),
#   4. exposes the LSP edit/read toolset (find_symbol, replace_symbol_body).
#
# Run before pushing changes to the serena registry entry
# (agents/mcp/registry.yaml) or chezmoi/dot_serena/modify_serena_config.yml.
# The bats suite only covers serena's *config rendering*; this is the only
# check that the binary actually boots with that config and exposes tools.
#
# Exit codes:
#   0  passed, or skipped because serena isn't installed
#   1  serena is present but failed to boot / apply config / expose tools
#
# Not a bats test on purpose: it launches a live server (slow, needs the
# serena binary + LSP), so it lives behind `just smoke` / `just check`
# instead of the unit suite that runs in CI without serena.

set -euo pipefail

if ! command -v serena >/dev/null 2>&1; then
    echo "⚠️  serena not on PATH — skipping smoke test (install via 'dots sync')"
    exit 0
fi

OUT="$(mktemp)"
PID=""
cleanup() {
    if [[ -n "$PID" ]]; then
        kill "$PID" 2>/dev/null || true
    fi
    rm -f "$OUT"
}
trap cleanup EXIT

# The registry launches serena via the serena-mux wrapper (command: serena-mux
# in agents/mcp/registry.yaml); this boots the same daemon argv serena-mux
# spawns under the hood, validating that bare serena + our config comes up.
serena start-mcp-server \
    --context=claude-code \
    --project-from-cwd \
    --enable-web-dashboard=false \
    --open-web-dashboard=false </dev/null >"$OUT" 2>&1 &
PID=$!

# The tool-exposition marker is logged ~100ms after boot, before the long LSP
# load — so we don't need to wait for the language server. Cold start still
# pays uv resolution, so allow up to 30s. (macOS has no `timeout`, hence the
# manual poll.)
marker="Number of exposed tools:"
deadline=$((SECONDS + 30))
while ((SECONDS < deadline)); do
    grep -q "$marker" "$OUT" 2>/dev/null && break
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "✘ serena exited before exposing tools" >&2
        cat "$OUT" >&2
        exit 1
    fi
    sleep 0.5
done

if ! grep -q "$marker" "$OUT"; then
    echo "✘ serena did not expose tools within 30s" >&2
    tail -20 "$OUT" >&2
    exit 1
fi

fail=0
assert() { # <extended-regex> <description>
    if grep -qE "$1" "$OUT"; then
        echo "  ✓ $2"
    else
        echo "  ✘ $2 (no match for: $1)" >&2
        fail=1
    fi
}

echo "serena smoke test:"
assert "Starting Serena server"                  "boots without crashing"
assert "Auto-detected project root:"             "auto-detects project from cwd"
# Count 8 proves OUR excluded_tools is live — serena ships excluded_tools: [].
assert "excluded 8 tools:.*write_memory"         "applies managed excluded_tools (memory)"
assert "excluded 8 tools:.*onboarding"           "  ↳ onboarding excluded too"
assert "Exposed tools:.*find_symbol"             "exposes find_symbol"
assert "Exposed tools:.*replace_symbol_body"     "exposes replace_symbol_body"

if grep -qE "Traceback|PermissionError" "$OUT"; then
    echo "  ✘ serena logged a traceback / permission error" >&2
    grep -nE "Traceback|PermissionError" "$OUT" >&2
    fail=1
fi

if ((fail)); then
    echo "✘ serena smoke test FAILED" >&2
    exit 1
fi
echo "✓ serena smoke test passed"
