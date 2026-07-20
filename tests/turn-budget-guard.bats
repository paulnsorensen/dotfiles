#!/usr/bin/env bats
# Tests for the turn-budget-guard sub-agent ceiling hook.
#   agents/hooks/turn-budget-guard.sh  — bash bridge (self-locating)
#   agents/lib/turn-budget-guard.js    — turn/byte counter + decision logic
#   chezmoi/dot_config/opencode/plugins/turn-budget-guard.js — opencode adapter
#
# Behavior is exercised through the stdin/stdout hook protocol against a
# deployed-layout fixture (hooks/ + lib/ siblings), so the test covers both
# the bridge's path resolution and the Node logic. CLAUDE_TURN_BUDGET_DIR
# sandboxes state away from the real budget dir.
#
# State is append/marker files under the per-(session,agent) counter dir, not
# a single state.json: `turns` (1 byte per PreToolUse call, count = file
# size), `grace` (same pattern, byte-hard grace calls used), `nudged` /
# `hard-nudged` (marker files, existence = flag). Helpers below seed those
# files directly instead of writing a JSON blob.

load test_helper

HOOK_SH="$REAL_DOTFILES_DIR/agents/hooks/turn-budget-guard.sh"
HOOK_JS="$REAL_DOTFILES_DIR/agents/lib/turn-budget-guard.js"
OPENCODE_PLUGIN="$REAL_DOTFILES_DIR/chezmoi/dot_config/opencode/plugins/turn-budget-guard.js"

setup() {
    setup_test_env
    # Mirror the deployed layout: <root>/hooks/<bridge> + <root>/lib/<logic>.
    DEPLOY="$TEST_HOME/.claude"
    mkdir -p "$DEPLOY/hooks" "$DEPLOY/lib"
    cp "$HOOK_SH" "$DEPLOY/hooks/turn-budget-guard.sh"
    cp "$HOOK_JS" "$DEPLOY/lib/turn-budget-guard.js"
    chmod +x "$DEPLOY/hooks/turn-budget-guard.sh"

    export CLAUDE_TURN_BUDGET_DIR="$TEST_HOME/budget"
    export CLAUDE_TURN_BUDGET_LOG="$TEST_HOME/turn-budget-decisions.jsonl"
    export PROJ="$TEST_HOME/projects/proj"
    mkdir -p "$PROJ"
}

teardown() {
    teardown_test_env
}

# ── helpers ──────────────────────────────────────────────────────────

# Seed the turns counter to N by appending N bytes to the `turns` file.
seed_turns() {
    local session="$1" agent="$2" turns="$3"
    local dir="$CLAUDE_TURN_BUDGET_DIR/$session/$agent"
    mkdir -p "$dir"
    node -e 'require("fs").writeFileSync(process.argv[1], "x".repeat(Number(process.argv[2])))' \
        "$dir/turns" "$turns"
}

# Seed the grace counter to N by appending N bytes to the `grace` file.
seed_grace() {
    local session="$1" agent="$2" grace="$3"
    local dir="$CLAUDE_TURN_BUDGET_DIR/$session/$agent"
    mkdir -p "$dir"
    node -e 'require("fs").writeFileSync(process.argv[1], "x".repeat(Number(process.argv[2])))' \
        "$dir/grace" "$grace"
}

mark_nudged() {
    local session="$1" agent="$2"
    local dir="$CLAUDE_TURN_BUDGET_DIR/$session/$agent"
    mkdir -p "$dir"
    : > "$dir/nudged"
}

mark_hard_nudged() {
    local session="$1" agent="$2"
    local dir="$CLAUDE_TURN_BUDGET_DIR/$session/$agent"
    mkdir -p "$dir"
    : > "$dir/hard-nudged"
}

# Mark that a real (non-zero) context reading has already been observed for
# this agent. A live mid-run agent always has this marker (its earlier
# PreToolUse calls read real tokens); seed it in tests that fake a mid-run
# agent via seed_turns, so grace eligibility correctly treats a mid-run
# over-hard crossing as ineligible (not a transient-miss resume).
mark_real_reading_seen() {
    local session="$1" agent="$2"
    local dir="$CLAUDE_TURN_BUDGET_DIR/$session/$agent"
    mkdir -p "$dir"
    : > "$dir/real-reading-seen"
}

# Current turns count for (session, agent) — 0 when the file is absent.
turns_count() {
    local file="$CLAUDE_TURN_BUDGET_DIR/$1/$2/turns"
    [[ -f "$file" ]] && wc -c < "$file" | tr -d ' ' || echo 0
}

# Current grace-used count for (session, agent) — 0 when the file is absent.
grace_count() {
    local file="$CLAUDE_TURN_BUDGET_DIR/$1/$2/grace"
    [[ -f "$file" ]] && wc -c < "$file" | tr -d ' ' || echo 0
}

# Write a transcript fixture of N bytes at the real located path.
seed_transcript() {
    local session="$1" agent="$2" bytes="$3"
    local dir="$PROJ/$session/subagents"
    mkdir -p "$dir"
    node -e 'require("fs").writeFileSync(process.argv[1], "x".repeat(Number(process.argv[2])))' \
        "$dir/agent-$agent.jsonl" "$bytes"
}

# Write a real transcript fixture: one assistant JSONL line per "usage"
# spec arg, each shaped input_tokens:cache_creation:cache_read. The probe
# reads only the LAST matching line's summed usage.
seed_usage_transcript() {
    local session="$1" agent="$2"; shift 2
    local dir="$PROJ/$session/subagents"
    mkdir -p "$dir"
    local file="$dir/agent-$agent.jsonl"
    : > "$file"
    local spec inp cc cr
    for spec in "$@"; do
        IFS=':' read -r inp cc cr <<< "$spec"
        jq -nc --argjson inp "$inp" --argjson cc "$cc" --argjson cr "$cr" \
            '{type:"assistant", message:{usage:{input_tokens:$inp, cache_creation_input_tokens:$cc, cache_read_input_tokens:$cr}}}' \
            >> "$file"
    done
}

file_size() {
    node -e 'try { process.stdout.write(String(require("fs").statSync(process.argv[1]).size)) } catch { process.stdout.write("0") }' "$1"
}

log_record() {
    local index="${1:--1}"
    jq -s ".[$index]" "$CLAUDE_TURN_BUDGET_LOG"
}

log_count() {
    if [[ -f "$CLAUDE_TURN_BUDGET_LOG" ]]; then
        wc -l < "$CLAUDE_TURN_BUDGET_LOG" | tr -d ' '
    else
        echo 0
    fi
}

# Fire one hook event; capture status + stdout into $output.
fire() {
    local json="$1"
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/turn-budget-guard.sh'"
    [ "$status" -eq 0 ]
}

# Emit "deny" | "nudge" | "allow" from the last hook output.
verdict() {
    if [[ -z "$output" ]]; then
        echo "allow"
    elif jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null 2>&1; then
        echo "deny"
    elif jq -e '.hookSpecificOutput.additionalContext != null' <<<"$output" >/dev/null 2>&1; then
        echo "nudge"
    else
        echo "unknown"
    fi
}

pre_event() {
    local session="$1" agent="$2" type="$3"
    jq -nc --arg s "$session" --arg a "$agent" --arg t "$type" --arg p "$PROJ/$session.jsonl" \
        '{hook_event_name:"PreToolUse", agent_id:$a, agent_type:$t, session_id:$s, transcript_path:$p, tool_name:"Bash", tool_input:{}}'
}

post_event() {
    local session="$1" agent="$2" type="$3"
    jq -nc --arg s "$session" --arg a "$agent" --arg t "$type" --arg p "$PROJ/$session.jsonl" \
        '{hook_event_name:"PostToolUse", agent_id:$a, agent_type:$t, session_id:$s, transcript_path:$p, tool_name:"Bash", tool_input:{}}'
}

# ── A1 — hard turn wall ──────────────────────────────────────────────

@test "A1: coder at 100 turns -> next call (101) is denied" {
    seed_turns s1 a1 100
    fire "$(pre_event s1 a1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"budget exceeded"* ]]
}

@test "A1: coder at 99 turns -> next call (100) is allowed" {
    seed_turns s1 a1 99
    fire "$(pre_event s1 a1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A1: PreToolUse increments the turns counter by exactly one" {
    seed_turns s1 a1 10
    fire "$(pre_event s1 a1 coder)"
    [[ "$(turns_count s1 a1)" == "11" ]]
}

@test "A1: hard-ceiling deny message tells the orchestrator to re-dispatch" {
    seed_turns s1 a1 100
    fire "$(pre_event s1 a1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"status: blocked: out of context"* ]]
}

# ── A2 ── hard context wall ──────────────────────────────────────

@test "A2: tokens over the context-hard ceiling denies immediately (non-resumed agent)" {
    # turns=5 -> increments to 6 on this call, so this is NOT the agent's
    # first observed call and grace does not apply, regardless of the token
    # reading. This is the Change 3 fix: a normal agent that crosses hard
    # mid-run gets an immediate deny, not a multi-call grace window.
    # A live mid-run agent has already logged real readings, so seed the
    # real-reading-seen marker; without it, an over-hard crossing would look
    # like a transient-miss resume and wrongly earn grace.
    seed_turns s2 b1 5
    mark_real_reading_seen s2 b1
    seed_usage_transcript s2 b1 "$((130000 + 1)):0:0"  # > ctxHard (130000)
    fire "$(pre_event s2 b1 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A2: under both turn and context ceilings -> allow" {
    seed_turns s2 b1 5
    seed_usage_transcript s2 b1 "100000:0:0"
    fire "$(pre_event s2 b1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2: PreToolUse allow writes a JSONL decision without stdout noise" {
    seed_turns s2 log1 5
    seed_usage_transcript s2 log1 "100000:0:0"
    fire "$(pre_event s2 log1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.event')" == "PreToolUse" ]]
    [[ "$(log_record | jq -r '.action')" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]
    [[ "$(log_record | jq -r '.agent_id')" == "log1" ]]
    [[ "$(log_record | jq -r '.budget_type')" == "coder" ]]
    [[ "$(log_record | jq -r '.turns')" == "6" ]]
    [[ "$(log_record | jq -r '.tokens')" == "100000" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "tokens" ]]
}

@test "A2: tokens exactly AT the context-hard ceiling -> allow (strict '>')" {
    # ctxHard = 130000. The wall is `tokens > ctxHard`, so a transcript
    # sitting exactly on the ceiling must still pass. Mirrors the A1 turn
    # boundary; a `>=` regression would deny here.
    seed_turns s2 b2 5
    seed_usage_transcript s2 b2 "130000:0:0"
    fire "$(pre_event s2 b2 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2: PreToolUse deny writes a deny record while stdout stays hook JSON" {
    seed_turns s2 log2 100
    fire "$(pre_event s2 log2 coder)"
    [[ "$(verdict)" == "deny" ]]
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.action')" == "deny" ]]
    [[ "$(log_record | jq -r '.reason')" == "hard-ceiling" ]]
    [[ "$(log_record | jq -r '.turnHard')" == "100" ]]
}

@test "A2: Codex direct agent_transcript_path drives the context ceiling" {
    seed_turns s2 codex1 1  # increments to 2 -> not first call, grace does not apply
    mark_real_reading_seen s2 codex1  # live mid-run agent has seen real readings
    local agent_tx="$TEST_HOME/codex-agent.jsonl"
    jq -nc --argjson inp $((130000 + 1)) \
        '{type:"assistant", message:{usage:{input_tokens:$inp, cache_creation_input_tokens:0, cache_read_input_tokens:0}}}' \
        > "$agent_tx"
    local json
    json=$(jq -nc --arg p "$agent_tx" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_id:"codex1",agent_type:"coder",session_id:"s2",agent_transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.harness')" == "codex" ]]
    [[ "$(log_record | jq -r '.tokens')" == "$((130000 + 1))" ]]
}

@test "A2: Codex standard agent_id and agent_type still enforce the turn wall" {
    seed_turns s2 codex2 100
    seed_usage_transcript s2 codex2 "100000:0:0"
    local json
    json=$(jq -nc --arg p "$PROJ/s2.jsonl" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_id:"codex2",agent_type:"coder",session_id:"s2",transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "deny" ]]
    jq -s -e 'length == 1 and .[0].harness == "codex" and .[0].action == "deny" and .[0].budget_type == "coder"' "$CLAUDE_TURN_BUDGET_LOG" >/dev/null
}

# ── A2b ── resume-only context-hard grace window ───────────────

@test "A2b: an agent whose FIRST call is already over context-hard gets exactly 3 grace allows, then a deny" {
    # No seed_turns call: the agent's first PreToolUse is turns=1, and the
    # transcript is already over ctxHard on that first call — the resume
    # signature that earns the grace window.
    seed_usage_transcript s2b grace1 "$((130000 + 1)):0:0"

    fire "$(pre_event s2b grace1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "ctx-grace" ]]
    [[ "$(grace_count s2b grace1)" == "1" ]]

    fire "$(pre_event s2b grace1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(grace_count s2b grace1)" == "2" ]]

    fire "$(pre_event s2b grace1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(grace_count s2b grace1)" == "3" ]]

    fire "$(pre_event s2b grace1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(grace_count s2b grace1)" == "3" ]]  # grace does not increment past the cap
    [[ "$output" == *"status: blocked: out of context"* ]]
}

@test "A2b: an agent that STARTS below context-hard and later crosses it is denied immediately, no grace" {
    # First call (turns=1) has a transcript under ctxHard, so graceEligible
    # is never set. A later call that crosses ctxHard gets no grace window
    # at all -- the Change 3 fix.
    seed_usage_transcript s2b grace2 "50000:0:0"  # under ctxHard on the first call
    fire "$(pre_event s2b grace2 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]

    seed_usage_transcript s2b grace2 "$((130000 + 1)):0:0"  # crosses ctxHard on the SECOND call
    fire "$(pre_event s2b grace2 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(grace_count s2b grace2)" == "0" ]]  # never granted, never consumed
}

@test "A2b: a resumed agent whose first call misses the transcript (tokens=0) still earns grace on a later over-hard reading" {
    # Simulate a resume already past turn 1 (state.turns != 1), whose first
    # observed call hits a transient transcript-not-found miss: tokens=0,
    # so real-reading-seen never gets marked. seenBefore stays false, so a
    # later over-hard reading still latches grace eligibility even though
    # turns != 1 -- the !seenBefore branch of the eligibility gate.
    seed_turns s2b grace3 5

    # First call: no transcript seeded -> tokens=0, ctx_source "none".
    fire "$(pre_event s2b grace3 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]
    [[ "$(log_record | jq -r '.tokens')" == "0" ]]

    # Second call: transcript now over ctxHard, turns is 7 (not 1) -- still
    # grace-eligible because no real reading was seen before this one.
    seed_usage_transcript s2b grace3 "$((130000 + 1)):0:0"
    fire "$(pre_event s2b grace3 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "ctx-grace" ]]
    [[ "$(grace_count s2b grace3)" == "1" ]]
}

# ── A3 — soft nudge fires once ───────────────────────────────────────

@test "A3: PostToolUse crossing the soft turn threshold nudges once, then never repeats" {
    seed_turns s3 c1 75  # coder turnSoft = 75
    fire "$(post_event s3 c1 coder)"
    [[ "$(verdict)" == "nudge" ]]
    [[ "$output" == *"wrap up"* ]]

    # Marker set — a second PostToolUse must not nudge again.
    fire "$(post_event s3 c1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A3: nudge is logged once and later PostToolUse records already-nudged" {
    seed_turns s3 log3 75
    fire "$(post_event s3 log3 coder)"
    [[ "$(verdict)" == "nudge" ]]
    fire "$(post_event s3 log3 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "2" ]]
    [[ "$(log_record 0 | jq -r '.action')" == "nudge" ]]
    [[ "$(log_record 0 | jq -r '.reason')" == "soft-threshold" ]]
    [[ "$(log_record 1 | jq -r '.action')" == "allow" ]]
    [[ "$(log_record 1 | jq -r '.reason')" == "already-nudged" ]]
}

@test "A3: PostToolUse does not increment the turn counter" {
    seed_turns s3 c1 75
    fire "$(post_event s3 c1 coder)"
    [[ "$(turns_count s3 c1)" == "75" ]]
}

@test "A3: soft context-token threshold nudges even when turns are low" {
    seed_turns s3 c2 1
    seed_usage_transcript s3 c2 "$((110000 + 1)):0:0"  # > ctxSoft (110000)
    fire "$(post_event s3 c2 coder)"
    [[ "$(verdict)" == "nudge" ]]
}

# ── A3b ── hard nudge (context-hard ceiling, PostToolUse) ───────────

@test "A3b: hard nudge fires once on first crossing and suppresses the soft nudge too" {
    seed_turns s3b d1 1
    seed_usage_transcript s3b d1 "$((130000 + 1)):0:0"
    fire "$(post_event s3b d1 coder)"
    [[ "$(verdict)" == "nudge" ]]
    [[ "$output" == *"hard ceiling"* ]]
    [[ "$output" == *"status: blocked: out of context"* ]]
    [[ -f "$CLAUDE_TURN_BUDGET_DIR/s3b/d1/hard-nudged" ]]
    [[ -f "$CLAUDE_TURN_BUDGET_DIR/s3b/d1/nudged" ]]

    # Second PostToolUse: already fully nudged, no repeat.
    fire "$(post_event s3b d1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "already-nudged" ]]
}

@test "A3b: hard nudge still fires even when the soft nudge already fired" {
    seed_turns s3b d2 1
    mark_nudged s3b d2
    seed_usage_transcript s3b d2 "$((130000 + 1)):0:0"
    fire "$(post_event s3b d2 coder)"
    [[ "$(verdict)" == "nudge" ]]
    [[ "$output" == *"hard ceiling"* ]]
    [[ -f "$CLAUDE_TURN_BUDGET_DIR/s3b/d2/hard-nudged" ]]
}

# ── A4 — orchestrator never capped ───────────────────────────────────

@test "A4: a call with no agent_id is always allowed regardless of state" {
    # No counter dir keyed to a top-level call exists; even a poisoned one
    # would be ignored because dispatch bails before touching state.
    local json
    json=$(jq -nc --arg p "$PROJ/s.jsonl" \
        '{hook_event_name:"PreToolUse", agent_type:"coder", session_id:"s", transcript_path:$p, tool_name:"Bash", tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
}

@test "A4: missing agent_id fail-opens and does NOT log without debug" {
    local json
    json=$(jq -nc --arg p "$PROJ/s.jsonl" \
        '{hook_event_name:"PreToolUse", agent_type:"coder", session_id:"s", transcript_path:$p, tool_name:"Bash", tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "0" ]]
}

@test "A4: missing agent_id IS logged when CLAUDE_TURN_BUDGET_DEBUG is set" {
    export CLAUDE_TURN_BUDGET_DEBUG=1
    local json
    json=$(jq -nc --arg p "$PROJ/s.jsonl" \
        '{hook_event_name:"PreToolUse", agent_type:"coder", session_id:"s", transcript_path:$p, tool_name:"Bash", tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.action')" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "no-agent-id" ]]
}

@test "A4: Codex payload without agent_id fail-opens and logs no-agent only under debug" {
    local json
    json=$(jq -nc --arg p "$PROJ/s.jsonl" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_type:"coder",session_id:"s",transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "0" ]]

    export CLAUDE_TURN_BUDGET_DEBUG=1
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.harness')" == "codex" ]]
    [[ "$(log_record | jq -r '.reason')" == "no-agent-id" ]]
}

# ── A5 — unknown agent_type -> default budget ────────────────────────

@test "A5: unknown agent_type falls to the default budget (hard 50)" {
    seed_turns s5 e1 50  # default turnHard = 50
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A5: unknown agent_type at 49 turns is allowed" {
    seed_turns s5 e1 49
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A5: unknown agent_type deny message names the default budget, not the raw type" {
    # The message must report the budget actually in force ('default'), not the
    # phantom incoming type — a triager reading 'wizard' would hunt for a
    # wizard-specific budget that was never applied.
    seed_turns s5 e1 50
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"type 'default'"* ]]
    [[ "$output" != *wizard* ]]
}

# ── A5b — general-purpose resolves the coder tier ────────────────────

@test "A5b: general-purpose at 99 turns -> next call (100) is allowed (coder ceiling)" {
    seed_turns s5b gp1 99
    fire "$(pre_event s5b gp1 general-purpose)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.budget_type')" == "general-purpose" ]]
}

@test "A5b: general-purpose at 100 turns -> next call (101) is denied (coder ceiling, not default)" {
    seed_turns s5b gp1 100
    fire "$(pre_event s5b gp1 general-purpose)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.turnHard')" == "100" ]]
}

# ── A6 — independent counters + scoped cleanup ───────────────────────

@test "A6: distinct agent_ids under one session count independently" {
    seed_turns s6 f1 99   # coder, one below the wall
    seed_turns s6 f2 100  # coder, at the wall
    fire "$(pre_event s6 f1 coder)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(pre_event s6 f2 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A6: same agent_id under distinct sessions counts independently" {
    # counterPath keys on BOTH session_id and agent_id. Two sub-agents that
    # happen to share an agent_id across different sessions must not collide;
    # a session-drop regression would read one shared counter and mis-verdict.
    seed_turns isoA z 5     # session isoA, agent z — well under the wall
    seed_turns isoB z 100   # session isoB, agent z — at the coder wall
    fire "$(pre_event isoA z coder)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(pre_event isoB z coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A6: SubagentStop removes only its own agent dir" {
    seed_turns s6 f1 5
    seed_turns s6 f2 5
    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"f1", agent_type:"coder", session_id:"s6"}')
    fire "$json"
    [[ ! -d "$CLAUDE_TURN_BUDGET_DIR/s6/f1" ]]
    [[ -d "$CLAUDE_TURN_BUDGET_DIR/s6/f2" ]]
}

# ── A7 — fail-open ───────────────────────────────────────────────────

@test "A7: empty stdin -> allow, no crash" {
    fire ""
    [[ "$(verdict)" == "allow" ]]
}

@test "A7: malformed stdin -> allow, no crash" {
    fire "not valid json {"
    [[ "$(verdict)" == "allow" ]]
}

@test "A7: unreadable turns file -> treated as zero, allow" {
    local dir="$CLAUDE_TURN_BUDGET_DIR/s7/g1"
    mkdir -p "$dir"
    printf 'x%.0s' {1..100} > "$dir/turns"
    chmod 000 "$dir/turns"
    fire "$(pre_event s7 g1 coder)"
    [[ "$(verdict)" == "allow" ]]
    chmod 644 "$dir/turns"
}

@test "A7: unlocatable transcript -> context signal 0, allow when turns are low" {
    seed_turns s7 g2 1
    # No transcript fixture written; contextTokens must resolve to 0.
    fire "$(pre_event s7 g2 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A7: logger write failure does not change enforcement" {
    export CLAUDE_TURN_BUDGET_LOG="$TEST_HOME"
    seed_turns s7 logfail 100
    fire "$(pre_event s7 logfail coder)"
    [[ "$(verdict)" == "deny" ]]
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
}

# ── A7b ── Codex agent_transcript_path stat failure falls through ────

@test "A7b: failed agent_transcript_path stat falls through to the transcript walk" {
    # No seed_turns: first call (turns=1) with an over-hard transcript from
    # the start -- the resume signature, so grace applies via the walk-
    # located fallback transcript.
    seed_usage_transcript s7b g3 "$((130000 + 1)):0:0"  # over-hard, locatable via the walk
    local json
    json=$(jq -nc --arg s "s7b" --arg a "g3" --arg p "$PROJ/s7b.jsonl" --arg atp "$TEST_HOME/does-not-exist.jsonl" \
        '{hook_event_name:"PreToolUse", agent_id:$a, agent_type:"coder", session_id:$s, transcript_path:$p, agent_transcript_path:$atp, tool_name:"Bash", tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "ctx-grace" ]]
    [[ "$(log_record | jq -r '.tokens')" == "$((130000 + 1))" ]]
}

# ── B ── real token-usage probe (last-assistant summed usage) ────────

@test "B1: token probe returns the summed LAST assistant usage line, not an earlier one" {
    seed_usage_transcript s10 tok1 "1000:0:0" "5000:2000:1000" "20000:5000:3000"
    fire "$(pre_event s10 tok1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.tokens')" == "28000" ]]
}

@test "B2: a transcript with no parseable JSON line falls back to the byte-size proxy on the token scale" {
    # Fallback is bytes / BYTES_PER_TOKEN_ESTIMATE (4): 12345 -> round -> 3086.
    seed_transcript s10 tok2 12345
    fire "$(pre_event s10 tok2 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.tokens')" == "3086" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "bytes-fallback" ]]
}

@test "B3: valid JSONL with no assistant usage line falls back to the byte-size proxy on the token scale" {
    local dir="$PROJ/s10/subagents"
    mkdir -p "$dir"
    local file="$dir/agent-tok3.jsonl"
    printf '{"type":"user","message":{"content":"hi"}}\n' > "$file"
    local size expected
    size=$(file_size "$file")
    expected=$(node -e "console.log(Math.round($size / 4))")
    fire "$(pre_event s10 tok3 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.tokens')" == "$expected" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "bytes-fallback" ]]
}

@test "B4: byte fallback that exceeds ctxHard on the token scale denies a mid-run agent" {
    # A transcript with no usage line and > 520000 bytes -> / 4 > 130000
    # tokens, so the fallback proxy must still enforce the hard ceiling.
    # seed_turns > 1 + real-reading-seen so this is a mid-run crossing (no
    # grace), proving the fallback denies on the token scale rather than
    # comparing raw bytes.
    seed_turns s10 tok4 5
    mark_real_reading_seen s10 tok4
    seed_transcript s10 tok4 520004  # 520004 / 4 = 130001 > ctxHard
    fire "$(pre_event s10 tok4 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "bytes-fallback" ]]
    [[ "$(log_record | jq -r '.tokens')" == "130001" ]]
}

@test "B5: a good-then-torn transcript keeps the last GOOD summed usage, not the byte fallback" {
    # Valid assistant usage lines followed by a half-written final line: the
    # per-line parse must skip the torn line and preserve the last good
    # reading (28000), NOT discard everything and drop to the byte proxy.
    seed_usage_transcript s10 tok5 "1000:0:0" "5000:2000:1000" "20000:5000:3000"
    local file="$PROJ/s10/subagents/agent-tok5.jsonl"
    printf '{"type":"assistant","message":{"usage":{"input_tokens":9\n' >> "$file"
    fire "$(pre_event s10 tok5 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.tokens')" == "28000" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "tokens" ]]
}

@test "B6: a resume whose first call misses the transcript still earns grace on its first over-hard reading" {
    # #9: on turns=1 the transcript is unlocatable (tokens=0 -> no real
    # reading, no eligibility yet). On turns=2 the located transcript is
    # over ctxHard; because no real reading was ever seen, this latches
    # grace-eligibility (the transient-miss resume path) rather than denying
    # like a fresh mid-run crosser.
    # Call 1: no transcript fixture -> contextTokens resolves to 0.
    fire "$(pre_event s10 tok6 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]
    # Call 2: transcript now present and over-hard -> grace, not deny.
    seed_usage_transcript s10 tok6 "$((130000 + 1)):0:0"
    fire "$(pre_event s10 tok6 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "ctx-grace" ]]
}

# ── A8 — stale sweep ─────────────────────────────────────────────────

# Set a file's mtime N hours in the past. `touch -d "@epoch"` is a GNU-ism
# that BSD/macOS touch rejects, so backdate via fs.utimesSync instead.
backdate_mtime() {
    local file="$1" hours="$2"
    node -e 'const fs=require("fs"); const past=new Date(Date.now()-Number(process.argv[2])*3600*1000); fs.utimesSync(process.argv[1], past, past);' \
        "$file" "$hours"
}

@test "A8: any invocation prunes agent dirs whose turns file is stale, keeps fresh ones" {
    seed_turns sOld old 1
    seed_turns sOld new 1
    # Backdate the stale one's TURNS FILE mtime past the 6h cutoff.
    backdate_mtime "$CLAUDE_TURN_BUDGET_DIR/sOld/old/turns" 10

    # Fire an unrelated event to trigger the backstop sweep.
    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"zzz", session_id:"sZ"}')
    fire "$json"

    [[ ! -d "$CLAUDE_TURN_BUDGET_DIR/sOld/old" ]]
    [[ -d "$CLAUDE_TURN_BUDGET_DIR/sOld/new" ]]
}

@test "A8: sweepStale spares a dir with no turns file" {
    # A dir mid-creation (mkdir done, turns not yet written) must not be
    # swept just because it exists — the sweep keys on the turns file.
    mkdir -p "$CLAUDE_TURN_BUDGET_DIR/sHalf/h1"
    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"zzz", session_id:"sZ"}')
    fire "$json"
    [[ -d "$CLAUDE_TURN_BUDGET_DIR/sHalf/h1" ]]
}

@test "A8: sweepStale falls back to a legacy state.json mtime when turns is absent" {
    local dir="$CLAUDE_TURN_BUDGET_DIR/sLegacy/leg1"
    mkdir -p "$dir"
    printf '{"turns":5}' > "$dir/state.json"
    backdate_mtime "$dir/state.json" 10

    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"zzz", session_id:"sZ"}')
    fire "$json"

    [[ ! -d "$dir" ]]
}

# ── A10 — decision log rotation ──────────────────────────────────────

@test "A10: decisions.jsonl rotates to one .1 generation once it crosses 5MB" {
    dd if=/dev/zero of="$CLAUDE_TURN_BUDGET_LOG" bs=1M count=6 2>/dev/null
    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"rot1", agent_type:"coder", session_id:"sRot"}')
    fire "$json"

    [[ -f "$CLAUDE_TURN_BUDGET_LOG.1" ]]
    local rotated_size
    rotated_size=$(file_size "$CLAUDE_TURN_BUDGET_LOG.1")
    [[ "$rotated_size" -ge $((6 * 1024 * 1024)) ]]
    [[ "$(log_count)" == "1" ]]
}

@test "A10: a second rotation overwrites .1 instead of accumulating a .2" {
    dd if=/dev/zero of="$CLAUDE_TURN_BUDGET_LOG" bs=1M count=6 2>/dev/null
    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"rot2", agent_type:"coder", session_id:"sRot"}')
    fire "$json"
    [[ -f "$CLAUDE_TURN_BUDGET_LOG.1" ]]

    dd if=/dev/zero of="$CLAUDE_TURN_BUDGET_LOG" bs=1M count=6 2>/dev/null
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"rot3", agent_type:"coder", session_id:"sRot"}')
    fire "$json"

    [[ -f "$CLAUDE_TURN_BUDGET_LOG.1" ]]
    [[ ! -f "$CLAUDE_TURN_BUDGET_LOG.2" ]]
}

# ── A11 — turn counts derive from file size ──────────────────────────

@test "A11: two PreToolUse increments produce a turns file of size 2 (no lost counts)" {
    local json
    json=$(pre_event s11 h1 coder)
    fire "$json"
    fire "$json"
    [[ "$(turns_count s11 h1)" == "2" ]]
}

# ── A9 — opencode plugin adapter ─────────────────────────────────────

@test "A9: opencode plugin fail-opens and logs when no stable sub-agent id exists" {
    export CLAUDE_TURN_BUDGET_DEBUG=1
    run env \
        DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        CLAUDE_TURN_BUDGET_DIR="$CLAUDE_TURN_BUDGET_DIR" \
        CLAUDE_TURN_BUDGET_LOG="$CLAUDE_TURN_BUDGET_LOG" \
        CLAUDE_TURN_BUDGET_DEBUG="$CLAUDE_TURN_BUDGET_DEBUG" \
        OPENCODE_PLUGIN="$OPENCODE_PLUGIN" \
        node --input-type=module -e '
            const plugin = await import(process.env.OPENCODE_PLUGIN);
            const hooks = await plugin.TurnBudgetGuard({ directory: process.cwd(), session: { id: "op-s" } });
            await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "echo ok" } });
        '
    assert_success
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.harness')" == "opencode" ]]
    [[ "$(log_record | jq -r '.action')" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "no-agent-id" ]]
}

@test "A9: opencode plugin denies when shared guard denies stable sub-agent" {
    seed_turns op-s op-a 100
    run env \
        DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        CLAUDE_TURN_BUDGET_DIR="$CLAUDE_TURN_BUDGET_DIR" \
        CLAUDE_TURN_BUDGET_LOG="$CLAUDE_TURN_BUDGET_LOG" \
        OPENCODE_PLUGIN="$OPENCODE_PLUGIN" \
        node --input-type=module -e '
            const plugin = await import(process.env.OPENCODE_PLUGIN);
            const client = { session: { get: async () => ({ data: { parentID: "op-s", agent: "coder" } }) } };
            const hooks = await plugin.TurnBudgetGuard({ directory: process.cwd(), client });
            await hooks["tool.execute.before"](
                { tool: "bash", sessionID: "op-a", callID: "c1" },
                { args: { command: "echo ok" } },
            );
        '
    [[ "$status" -ne 0 ]]
    [[ "$(log_record | jq -r '.harness')" == "opencode" ]]
    [[ "$(log_record | jq -r '.action')" == "deny" ]]
}
