#!/usr/bin/env bash
# Stop hook (Claude Code): keep an existing wheypoint current.
#
# A wheypoint record does not store the session id, so detection reads the
# session transcript (`transcript_path` in the Stop payload, Claude JSONL).
# The hook acts only when the session already ran a successful
# `wheypoint.pyz checkpoint` Bash call. The wheypoint is stale when, after the
# LAST successful checkpoint, the transcript holds a genuine user prompt or any
# tool call other than a wheypoint command (`wheypoint.pyz ...` or the
# wheypoint Skill). Reads count: new context belongs in the wheypoint.
# A stale wheypoint blocks the stop with {decision:"block", reason}.
#
# Loop safety: `stop_hook_active: true` exits 0, so the hook never blocks twice
# in a row.
# Fail-open: a missing jq, payload, or transcript, or any error, exits 0 with
# no output. jq streams the transcript line by line (bounded memory) and skips
# lines that do not parse.
# Claude-only: Codex Stop payloads carry no Claude-format transcript_path.
# Opt out with WHEYPOINT_STOP_GUARD=0|false|off|no.

set -euo pipefail
trap 'exit 0' ERR

case "$(printf '%s' "${WHEYPOINT_STOP_GUARD:-1}" | tr '[:upper:]' '[:lower:]')" in
    0 | false | off | no) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
[[ -n "$input" ]] || exit 0
[[ "$(jq -r '.stop_hook_active // empty' <<<"$input" 2>/dev/null)" == "true" ]] && exit 0
transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
[[ -n "$transcript" && -r "$transcript" ]] || exit 0

# shellcheck disable=SC2016  # the jq program is single-quoted on purpose
verdict="$(jq -nRr '
  def text: if type == "string" then .
            elif type == "array" then map(.text? // "") | join("")
            else "" end;
  def blocks: (.message.content // []) | if type == "array" then . else [] end;
  def cp_re: "wheypoint\\.pyz[\"\\x27]?\\s+(\\S+\\s+){0,3}?checkpoint(\\s|$|[\"\\x27<;&|])";
  def injected: test("^\\s*<(system-reminder|command-|local-command-|task-notification|user-prompt-submit-hook)")
                or test("^\\s*(Stop hook feedback|\\[Request interrupted)");

  reduce (inputs | fromjson? | select(type == "object" and (.isSidechain != true))) as $e
    ({cp: {}, have: false, stale: false, ref: ""};
      if $e.type == "assistant" then
        reduce ($e | blocks[] | select(.type == "tool_use")) as $t (.;
          ($t.input.command? // "") as $cmd
          | if $t.name == "Bash" and ($cmd | test(cp_re)) then .cp[$t.id] = true
            elif $t.name == "Bash" and ($cmd | test("wheypoint\\.pyz")) then .
            elif $t.name == "Skill" and (($t.input.skill? // $t.input.name? // $t.input.command? // "") | tostring | test("wheypoint")) then .
            elif .have then .stale = true
            else . end)
      elif $e.type == "user" and ($e.isMeta != true) then
        ($e.message.content // "") as $c
        | if ($c | type) == "string" then
            (if .have and ($c | injected | not) and ($c | test("\\S")) then .stale = true else . end)
          else
            reduce ($c[]? | select(type == "object")) as $b (.;
              if $b.type == "tool_result" then
                (($b.content // "") | text) as $out
                | if .cp[$b.tool_use_id // ""] == true and ($b.is_error != true)
                     and ($out | test("\"ok\"\\s*:\\s*true")) then
                    .have = true | .stale = false
                    | .ref = ($out | capture("\"work_id\"\\s*:\\s*\"(?<w>[^\"]+)\"").w? // "")
                  else . end
              elif $b.type == "text" and .have and ((($b.text // "") | injected) | not)
                   and (($b.text // "") | test("\\S")) then .stale = true
              else . end)
          end
      else . end)
  | if .have and .stale then "stale\t" + .ref else "ok" end
' "$transcript" 2>/dev/null)" || exit 0

[[ "$verdict" == stale* ]] || exit 0
ref="${verdict#stale}"
ref="${ref#$'\t'}"

reason="The session changed after its last wheypoint checkpoint. Run /wheypoint to fold the new decisions, findings, and context into the same work item."
[[ -n "$ref" ]] && reason="$reason Work item: $ref."

jq -cn --arg r "$reason" '{decision:"block",reason:$r}'
exit 0
