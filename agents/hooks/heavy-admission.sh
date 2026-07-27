#!/usr/bin/env bash
# PreToolUse: require heavy-run for compiler/linker-heavy agent commands.

set -u
command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat) || exit 0
[[ "$(jq -r '.tool_name // ""' <<<"$payload")" == Bash ]] || exit 0
command=$(jq -r '.tool_input.command // ""' <<<"$payload")

heavy_re='(^|[[:space:];|&])(sudo[[:space:]]+)?(cargo[[:space:]]+(build|test|check|clippy|nextest|bench|run)|rustc|rust-lld|ld[.]lld|mold|just[[:space:]]+(ci|llm))([[:space:];|&]|$)'
[[ "$command" =~ $heavy_re ]] || exit 0

route_re='(^|[[:space:];|&])heavy-run([[:space:];|&]|$)'
[[ "$command" =~ $route_re ]] && exit 0

jq -cn --arg reason "Blocked: compiler/linker-heavy commands must run through heavy-run so only one admitted job can use the development I/O budget. Example: heavy-run $command" \
    '{hookSpecificOutput:{permissionDecision:"deny",permissionDecisionReason:$reason}}'
