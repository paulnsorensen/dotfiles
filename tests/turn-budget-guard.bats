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

# Seed a counter dir's state.json with a given turn count / nudged flag.
seed_state() {
    local session="$1" agent="$2" turns="$3" nudged="${4:-false}"
    local dir="$CLAUDE_TURN_BUDGET_DIR/$session/$agent"
    mkdir -p "$dir"
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({turns:Number(process.argv[2]),nudged:process.argv[3]==="true"}))' \
        "$dir/state.json" "$turns" "$nudged"
}

# Write a transcript fixture of N bytes at the real located path.
seed_transcript() {
    local session="$1" agent="$2" bytes="$3"
    local dir="$PROJ/$session/subagents"
    mkdir -p "$dir"
    node -e 'require("fs").writeFileSync(process.argv[1], "x".repeat(Number(process.argv[2])))' \
        "$dir/agent-$agent.jsonl" "$bytes"
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
    seed_state s1 a1 100
    fire "$(pre_event s1 a1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"budget exceeded"* ]]
}

@test "A1: coder at 99 turns -> next call (100) is allowed" {
    seed_state s1 a1 99
    fire "$(pre_event s1 a1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A1: PreToolUse increments the counter by exactly one" {
    seed_state s1 a1 10
    fire "$(pre_event s1 a1 coder)"
    local turns
    turns=$(jq -r '.turns' "$CLAUDE_TURN_BUDGET_DIR/s1/a1/state.json")
    [[ "$turns" == "11" ]]
}

# ── A2 — hard byte wall ──────────────────────────────────────────────

@test "A2: byte size over the byte-hard ceiling denies even under the turn wall" {
    seed_state s2 b1 5
    seed_transcript s2 b1 $((920 * 1024))  # coder byteHard = 891 KB
    fire "$(pre_event s2 b1 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A2: under both turn and byte ceilings -> allow" {
    seed_state s2 b1 5
    seed_transcript s2 b1 $((100 * 1024))
    fire "$(pre_event s2 b1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2: PreToolUse allow writes a JSONL decision without stdout noise" {
    seed_state s2 log1 5
    seed_transcript s2 log1 $((100 * 1024))
    fire "$(pre_event s2 log1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.event')" == "PreToolUse" ]]
    [[ "$(log_record | jq -r '.action')" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]
    [[ "$(log_record | jq -r '.agent_id')" == "log1" ]]
    [[ "$(log_record | jq -r '.budget_type')" == "coder" ]]
    [[ "$(log_record | jq -r '.turns')" == "6" ]]
    [[ "$(log_record | jq -r '.bytes')" == "$((100 * 1024))" ]]
}

@test "A2: bytes exactly AT the byte-hard ceiling -> allow (strict '>')" {
    # coder byteHard = 891*1024 = 912384. The wall is `bytes > byteHard`, so
    # a transcript sitting exactly on the ceiling must still pass. Mirrors the
    # A1 turn boundary; a `>=` regression would deny here.
    seed_state s2 b2 5
    seed_transcript s2 b2 $((891 * 1024))
    fire "$(pre_event s2 b2 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2: bytes one over the byte-hard ceiling -> deny" {
    seed_state s2 b3 5
    seed_transcript s2 b3 $((891 * 1024 + 1))
    fire "$(pre_event s2 b3 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A2: PreToolUse deny writes a deny record while stdout stays hook JSON" {
    seed_state s2 log2 100
    fire "$(pre_event s2 log2 coder)"
    [[ "$(verdict)" == "deny" ]]
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.action')" == "deny" ]]
    [[ "$(log_record | jq -r '.reason')" == "hard-ceiling" ]]
    [[ "$(log_record | jq -r '.turnHard')" == "100" ]]
}

@test "A2: Codex direct agent_transcript_path drives byte ceiling" {
    seed_state s2 codex1 1
    local agent_tx="$TEST_HOME/codex-agent.jsonl"
    node -e 'require("fs").writeFileSync(process.argv[1], "x".repeat(Number(process.argv[2])))' \
        "$agent_tx" $((920 * 1024))
    local json
    json=$(jq -nc --arg p "$agent_tx" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_id:"codex1",agent_type:"coder",session_id:"s2",agent_transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.harness')" == "codex" ]]
    [[ "$(log_record | jq -r '.bytes')" == "$((920 * 1024))" ]]
}

@test "A2: Codex standard agent_id and agent_type still enforce the turn wall" {
    seed_state s2 codex2 100
    seed_transcript s2 codex2 $((100 * 1024))
    local json
    json=$(jq -nc --arg p "$PROJ/s2.jsonl" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_id:"codex2",agent_type:"coder",session_id:"s2",transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "deny" ]]
    jq -s -e 'length == 1 and .[0].harness == "codex" and .[0].action == "deny" and .[0].budget_type == "coder"' "$CLAUDE_TURN_BUDGET_LOG" >/dev/null
}


# ── A3 — soft nudge fires once ───────────────────────────────────────

@test "A3: PostToolUse crossing the soft turn threshold nudges once, then never repeats" {
    seed_state s3 c1 75  # coder turnSoft = 75
    fire "$(post_event s3 c1 coder)"
    [[ "$(verdict)" == "nudge" ]]
    [[ "$output" == *"wrap up"* ]]

    # Marker set — a second PostToolUse must not nudge again.
    fire "$(post_event s3 c1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A3: nudge is logged once and later PostToolUse records already-nudged" {
    seed_state s3 log3 75
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
    seed_state s3 c1 75
    fire "$(post_event s3 c1 coder)"
    local turns
    turns=$(jq -r '.turns' "$CLAUDE_TURN_BUDGET_DIR/s3/c1/state.json")
    [[ "$turns" == "75" ]]
}

@test "A3: soft byte threshold nudges even when turns are low" {
    seed_state s3 c2 1
    seed_transcript s3 c2 $((400 * 1024))  # coder byteSoft = 368 KB
    fire "$(post_event s3 c2 coder)"
    [[ "$(verdict)" == "nudge" ]]
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

@test "A4: missing agent_id fail-opens and logs no-agent" {
    local json
    json=$(jq -nc --arg p "$PROJ/s.jsonl" \
        '{hook_event_name:"PreToolUse", agent_type:"coder", session_id:"s", transcript_path:$p, tool_name:"Bash", tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.action')" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "no-agent-id" ]]
}

@test "A4: Codex payload without agent_id fail-opens and logs no-agent" {
    local json
    json=$(jq -nc --arg p "$PROJ/s.jsonl" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_type:"coder",session_id:"s",transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.harness')" == "codex" ]]
    [[ "$(log_record | jq -r '.reason')" == "no-agent-id" ]]
}

# ── A5 — unknown agent_type -> default budget ────────────────────────

@test "A5: unknown agent_type falls to the default budget (hard 50)" {
    seed_state s5 e1 50  # default turnHard = 50
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A5: unknown agent_type at 49 turns is allowed" {
    seed_state s5 e1 49
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A5: unknown agent_type deny message names the default budget, not the raw type" {
    # The message must report the budget actually in force ('default'), not the
    # phantom incoming type — a triager reading 'wizard' would hunt for a
    # wizard-specific budget that was never applied.
    seed_state s5 e1 50
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"type 'default'"* ]]
    [[ "$output" != *wizard* ]]
}

# ── A6 — independent counters + scoped cleanup ───────────────────────

@test "A6: distinct agent_ids under one session count independently" {
    seed_state s6 f1 99   # coder, one below the wall
    seed_state s6 f2 100  # coder, at the wall
    fire "$(pre_event s6 f1 coder)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(pre_event s6 f2 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A6: same agent_id under distinct sessions counts independently" {
    # counterPath keys on BOTH session_id and agent_id. Two sub-agents that
    # happen to share an agent_id across different sessions must not collide;
    # a session-drop regression would read one shared counter and mis-verdict.
    seed_state isoA z 5     # session isoA, agent z — well under the wall
    seed_state isoB z 100   # session isoB, agent z — at the coder wall
    fire "$(pre_event isoA z coder)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(pre_event isoB z coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A6: SubagentStop removes only its own agent dir" {
    seed_state s6 f1 5
    seed_state s6 f2 5
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

@test "A7: unreadable/malformed state file -> treated as zero, allow" {
    local dir="$CLAUDE_TURN_BUDGET_DIR/s7/g1"
    mkdir -p "$dir"
    printf 'garbage' > "$dir/state.json"
    fire "$(pre_event s7 g1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A7: unlocatable transcript -> byte signal 0, allow when turns are low" {
    seed_state s7 g2 1
    # No transcript fixture written; contextBytes must resolve to 0.
    fire "$(pre_event s7 g2 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A7: logger write failure does not change enforcement" {
    export CLAUDE_TURN_BUDGET_LOG="$TEST_HOME"
    seed_state s7 logfail 100
    fire "$(pre_event s7 logfail coder)"
    [[ "$(verdict)" == "deny" ]]
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
}

# ── A8 — stale sweep ─────────────────────────────────────────────────

@test "A8: any invocation prunes agent dirs whose state.json is stale, keeps fresh ones" {
    seed_state sOld old 1
    seed_state sOld new 1
    # Backdate the stale one's STATE FILE mtime past the 6h cutoff.
    local ts
    ts=$(node -e 'const d=new Date(Date.now()-10*3600*1000); process.stdout.write(String(Math.floor(d.getTime()/1000)))')
    touch -d "@$ts" "$CLAUDE_TURN_BUDGET_DIR/sOld/old/state.json"

    # Fire an unrelated event to trigger the backstop sweep.
    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"zzz", session_id:"sZ"}')
    fire "$json"

    [[ ! -d "$CLAUDE_TURN_BUDGET_DIR/sOld/old" ]]
    [[ -d "$CLAUDE_TURN_BUDGET_DIR/sOld/new" ]]
}

@test "A8: sweepStale spares a dir with no state file" {
    # A dir mid-creation (mkdir done, state.json not yet written) must not be
    # swept just because it exists — the sweep keys on the state file.
    mkdir -p "$CLAUDE_TURN_BUDGET_DIR/sHalf/h1"
    local json
    json=$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"zzz", session_id:"sZ"}')
    fire "$json"
    [[ -d "$CLAUDE_TURN_BUDGET_DIR/sHalf/h1" ]]
}

# ── A9 — opencode plugin adapter ─────────────────────────────────────

@test "A9: opencode plugin fail-opens and logs when no stable sub-agent id exists" {
    run env \
        DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        CLAUDE_TURN_BUDGET_DIR="$CLAUDE_TURN_BUDGET_DIR" \
        CLAUDE_TURN_BUDGET_LOG="$CLAUDE_TURN_BUDGET_LOG" \
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
    seed_state op-s op-a 100
    run env \
        DOTFILES_DIR="$REAL_DOTFILES_DIR" \
        CLAUDE_TURN_BUDGET_DIR="$CLAUDE_TURN_BUDGET_DIR" \
        CLAUDE_TURN_BUDGET_LOG="$CLAUDE_TURN_BUDGET_LOG" \
        OPENCODE_PLUGIN="$OPENCODE_PLUGIN" \
        node --input-type=module -e '
            const plugin = await import(process.env.OPENCODE_PLUGIN);
            const hooks = await plugin.TurnBudgetGuard({ directory: process.cwd(), session: { id: "op-s" } });
            await hooks["tool.execute.before"](
                { tool: "bash", agent_id: "op-a", agent_type: "coder", session_id: "op-s" },
                { args: { command: "echo ok" } },
            );
        '
    [[ "$status" -ne 0 ]]
    [[ "$(log_record | jq -r '.harness')" == "opencode" ]]
    [[ "$(log_record | jq -r '.action')" == "deny" ]]
}
