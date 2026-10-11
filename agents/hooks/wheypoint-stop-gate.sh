#!/usr/bin/env bash
# Stop hook (Claude only): keep the session's wheypoint current, but only when
# work is in progress. The hook replaces a Haiku prompt hook that fired on
# every stop, including Q&A turns that changed nothing.
#
# "Work is in progress" means the transcript shows a file change after the last
# wheypoint (or after session start, when no wheypoint exists). A file change is
# a call to Edit, Write, MultiEdit, NotebookEdit, or tilth_write, or a Bash
# `git commit` or `git push`. Writes under /tmp and .cheese/ do not count.
#
#   no file change since the last wheypoint        -> allow the stop
#   wheypoint exists + file change after it        -> block: update it
#   no wheypoint + file change + dirty working tree -> block: write one
#   no wheypoint + file change + clean tree         -> allow (work is committed)
#
# stop_hook_active ends the follow-up, so a block cannot loop. The hook is
# deterministic: it never calls a model, so it costs nothing and cannot time out.
#
# Fail-open: missing jq, invalid stdin, an unreadable transcript, or any error
# exits 0 with no output. Opt out for a session with WHEYPOINT_STOP_GATE=0.

set -euo pipefail
trap 'exit 0' ERR

[[ "${WHEYPOINT_STOP_GATE:-1}" == "0" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
[[ -n "$input" ]] || exit 0
[[ "$(jq -r '.stop_hook_active // empty' <<<"$input" 2>/dev/null)" == "true" ]] && exit 0

transcript="$(jq -r '.transcript_path // empty' <<<"$input" 2>/dev/null)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)"
[[ -f "$transcript" ]] || exit 0
[[ -n "$cwd" ]] || cwd="$PWD"

# Fold the transcript in order: a wheypoint resets the change count to zero.
state="$(jq -rRn '
  def untracked: test("^/tmp/|/\\.cheese/");
  [ inputs | fromjson? | select(type == "object" and .type == "assistant")
    | .message.content? | select(type == "array") | .[]
    | if .type == "tool_use" then
        if .name == "Skill" and ((.input.skill? // "") | test("(^|:)wheypoint$")) then "W"
        elif (.name | test("^(Edit|Write|MultiEdit|NotebookEdit)$")) then
          if ((.input.file_path? // .input.notebook_path? // "") | untracked) then empty else "M" end
        elif .name == "mcp__tilth__tilth_write" then
          if ([.input.edits[]?.path? // empty | select(untracked | not)] | length) > 0 then "M" else empty end
        elif .name == "Bash" and ((.input.command? // "") | test("(^|[;&|] *)git +(commit|push)([^a-z-]|$)")) then "M"
        else empty end
      elif .type == "text" and ((.text // "") | contains("Wheypoint dropped:")) then "W"
      else empty end
  ]
  | reduce .[] as $e ({m: 0, w: false}; if $e == "W" then {m: 0, w: true} else .m += 1 end)
  | "\(.m) \(.w)"
' "$transcript")"

changes="${state%% *}"
has_wheypoint="${state##* }"
[[ "$changes" =~ ^[0-9]+$ ]] || exit 0
(( changes > 0 )) || exit 0

if [[ "$has_wheypoint" == "true" ]]; then
    reason="Update this session's wheypoint with /wheypoint, then stop."
else
    dirty="$(git -C "$cwd" status --porcelain -- . ':(exclude).cheese' 2>/dev/null)" || exit 0
    [[ -n "$dirty" ]] || exit 0
    reason="Work is uncommitted. Write a wheypoint with /wheypoint, then stop."
fi

jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
