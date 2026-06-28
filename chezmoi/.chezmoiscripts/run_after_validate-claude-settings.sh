#!/bin/bash
# run_after — validate the live ~/.claude/settings.json against the Claude Code
# settings schema after every apply. modify_settings.json (and ap's later
# merge) produce the live file, so the only place to schema-check the final
# result is here, post-apply. Fail loud on a violation; stay quiet otherwise.
#
# Skips gracefully when check-jsonschema is absent (it's a uv tool in
# packages.yaml, but may not be installed yet during an early bootstrap).
# Caching is left on so a schema fetch happens once, then offline syncs pass.
set -euo pipefail

target="$HOME/.claude/settings.json"
schema="https://json.schemastore.org/claude-code-settings.json"

[[ -f "$target" ]] || exit 0

if ! command -v check-jsonschema >/dev/null 2>&1; then
    echo "  check-jsonschema not installed — skipping Claude settings schema validation" >&2
    exit 0
fi

check-jsonschema --schemafile "$schema" "$target"
