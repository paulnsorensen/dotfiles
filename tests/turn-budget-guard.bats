#!/usr/bin/env bats
# Tests for the turn-budget-guard sub-agent ceiling hook.
#   agents/hooks/turn-budget-guard.sh  — bash bridge (self-locating)
#   agents/lib/turn-budget-guard.js    — context ceiling + auto-compact exemption logic
#
# Behavior is exercised through the stdin/stdout hook protocol against a
# deployed-layout fixture (hooks/ + lib/ siblings), so the test covers both
# the bridge's path resolution and the Node logic. CLAUDE_TURN_BUDGET_DIR
# sandboxes state away from the real budget dir.
#
# State is append/marker files under the per-(session,agent) counter dir, not
# a single state.json: `turns` (1 byte per PreToolUse call, count = file
# size), `checkpoint-spent`, `nudged` / `hard-nudged` (marker files,
# existence = flag). Helpers below seed those
# files directly instead of writing a JSON blob.

load test_helper

HOOK_SH="$REAL_DOTFILES_DIR/agents/hooks/turn-budget-guard.sh"
HOOK_JS="$REAL_DOTFILES_DIR/agents/lib/turn-budget-guard.js"

setup_file() {
    export GUARD_MASTER="$BATS_FILE_TMPDIR/guard-mocks"
    mkdir -p "$GUARD_MASTER/hooks" "$GUARD_MASTER/lib"
    cp "$HOOK_SH" "$GUARD_MASTER/hooks/turn-budget-guard.sh"
    cp "$HOOK_JS" "$GUARD_MASTER/lib/turn-budget-guard.js"
    chmod +x "$GUARD_MASTER/hooks/turn-budget-guard.sh"
}

setup() {
    setup_test_env
    # Mirror the deployed layout: <root>/hooks/<bridge> + <root>/lib/<logic>.
    # Symlink the setup_file-built master. Measurements showed a first-exec
    # delay for fresh script inodes. Symlinking reuses the target inode and
    # improved timings; the mechanism is unspecified.
    DEPLOY="$TEST_HOME/.claude"
    mkdir -p "$DEPLOY/hooks" "$DEPLOY/lib"
    ln -s "$GUARD_MASTER/hooks/turn-budget-guard.sh" "$DEPLOY/hooks/turn-budget-guard.sh"
    ln -s "$GUARD_MASTER/lib/turn-budget-guard.js" "$DEPLOY/lib/turn-budget-guard.js"

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

# Current turns count for (session, agent) — 0 when the file is absent.
turns_count() {
    local file="$CLAUDE_TURN_BUDGET_DIR/$1/$2/turns"
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

checkpoint_event() {
    local session="$1" agent="$2" type="$3" target="$4"
    jq -nc --arg s "$session" --arg a "$agent" --arg t "$type" --arg p "$PROJ/$session.jsonl" --arg cwd "$PROJ" --arg target "$target" \
        '{hook_event_name:"PreToolUse", agent_id:$a, agent_type:$t, session_id:$s, transcript_path:$p, tool_name:"mcp__tilth__tilth_write", tool_input:{cwd:$cwd, edits:[{path:$target, ops:[{op:"append",content:"checkpoint"}]}]}}'
}

handback_event() {
    local session="$1" agent="$2" type="$3"
    jq -nc --arg s "$session" --arg a "$agent" --arg t "$type" --arg p "$PROJ/$session.jsonl" \
        '{hook_event_name:"PreToolUse", agent_id:$a, agent_type:$t, session_id:$s, transcript_path:$p, tool_name:"SubagentHandback", tool_input:{message:"status: ok"}}'
}

structured_output_event() {
    local session="$1" agent="$2" type="$3"
    jq -nc --arg s "$session" --arg a "$agent" --arg t "$type" --arg p "$PROJ/$session.jsonl" \
        '{hook_event_name:"PreToolUse", agent_id:$a, agent_type:$t, session_id:$s, transcript_path:$p, tool_name:"StructuredOutput", tool_input:{status:"done"}}'
}

multiple_checkpoint_event() {
    local session="$1" agent="$2" type="$3"
    jq -nc --arg s "$session" --arg a "$agent" --arg t "$type" --arg p "$PROJ/$session.jsonl" --arg cwd "$PROJ" \
        '{hook_event_name:"PreToolUse", agent_id:$a, agent_type:$t, session_id:$s, transcript_path:$p, tool_name:"mcp__tilth__tilth_write", tool_input:{cwd:$cwd, edits:[{path:".cheese/one.md",ops:[{op:"append",content:"checkpoint"}]},{path:".context/two.md",ops:[{op:"append",content:"checkpoint"}]}]}}'
}

post_event() {
    local session="$1" agent="$2" type="$3"
    jq -nc --arg s "$session" --arg a "$agent" --arg t "$type" --arg p "$PROJ/$session.jsonl" \
        '{hook_event_name:"PostToolUse", agent_id:$a, agent_type:$t, session_id:$s, transcript_path:$p, tool_name:"Bash", tool_input:{}}'
}

# ── A1 — no turn wall; context wall only ─────────────────────────────

@test "A1: PreToolUse increments the turns counter by exactly one" {
    seed_turns s1 a1 10
    fire "$(pre_event s1 a1 coder)"
    [[ "$(turns_count s1 a1)" == "11" ]]
}

@test "A1: hard-ceiling deny message tells the orchestrator to re-dispatch" {
    seed_usage_transcript s1 a1 "$((180000 + 1)):0:0"
    fire "$(pre_event s1 a1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"status: needs-context"* ]]
    [[ "$output" == *"local guard budget"* ]]
    [[ "$output" == *"not a provider context failure"* ]]
    [[ "$output" == *"context 180001/180000 tokens"* ]]
    [[ "$output" != *"turns"* ]]
}

@test "A1: non-coder hard-ceiling message reports a blocker instead of needs-context" {
    seed_usage_transcript s1 reviewer1 "$((180000 + 1)):0:0"
    fire "$(pre_event s1 reviewer1 reviewer)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"status: blocked: <reason>"* ]]
    [[ "$output" != *"status: needs-context"* ]]
}

# ── A2 ── hard context wall ──────────────────────────────────────

@test "A2: Bash over the context-hard ceiling denies immediately" {
    seed_turns s2 b1 5
    seed_usage_transcript s2 b1 "$((180000 + 1)):0:0"  # > ctxHard (180000)
    fire "$(pre_event s2 b1 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A2: under both turn and context ceilings -> allow" {
    seed_turns s2 b1 5
    seed_usage_transcript s2 b1 "140000:0:0"
    fire "$(pre_event s2 b1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2: PreToolUse allow writes a JSONL decision without stdout noise" {
    seed_turns s2 log1 5
    seed_usage_transcript s2 log1 "140000:0:0"
    fire "$(pre_event s2 log1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.event')" == "PreToolUse" ]]
    [[ "$(log_record | jq -r '.action')" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]
    [[ "$(log_record | jq -r '.agent_id')" == "log1" ]]
    [[ "$(log_record | jq -r '.budget_type')" == "coder" ]]
    [[ "$(log_record | jq -r '.turns')" == "6" ]]
    [[ "$(log_record | jq -r '.tokens')" == "140000" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "tokens" ]]
}

@test "A2: tokens exactly AT the context-hard ceiling -> allow (strict '>')" {
    # ctxHard = 180000. The wall is `tokens > ctxHard`, so a transcript
    # sitting exactly on the ceiling must still pass. Mirrors the A1 turn
    # boundary; a `>=` regression would deny here.
    seed_turns s2 b2 5
    seed_usage_transcript s2 b2 "180000:0:0"
    fire "$(pre_event s2 b2 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2: PreToolUse deny writes a deny record while stdout stays hook JSON" {
    seed_usage_transcript s2 log2 "$((180000 + 1)):0:0"
    fire "$(pre_event s2 log2 coder)"
    [[ "$(verdict)" == "deny" ]]
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
    [[ "$(log_count)" == "1" ]]
    [[ "$(log_record | jq -r '.action')" == "deny" ]]
    [[ "$(log_record | jq -r '.reason')" == "hard-ceiling" ]]
    [[ "$(log_record | jq -r '.ctxHard')" == "180000" ]]
    [[ "$(log_record | jq -r '.turnHard')" == "null" ]]
}

@test "A2: Codex direct agent_transcript_path drives the context ceiling" {
    seed_turns s2 codex1 1
    local agent_tx="$TEST_HOME/codex-agent.jsonl"
    jq -nc --argjson inp $((180000 + 1)) \
        '{type:"assistant", message:{usage:{input_tokens:$inp, cache_creation_input_tokens:0, cache_read_input_tokens:0}}}' \
        > "$agent_tx"
    local json
    json=$(jq -nc --arg p "$agent_tx" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_id:"codex1",agent_type:"coder",session_id:"s2",agent_transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.harness')" == "codex" ]]
    [[ "$(log_record | jq -r '.tokens')" == "$((180000 + 1))" ]]
}

@test "A2: Codex standard agent_id and agent_type still enforce the context wall" {
    seed_usage_transcript s2 codex2 "$((180000 + 1)):0:0"
    local json
    json=$(jq -nc --arg p "$PROJ/s2.jsonl" \
        '{harness:"codex",hook_event_name:"PreToolUse",agent_id:"codex2",agent_type:"coder",session_id:"s2",transcript_path:$p,tool_name:"Bash",tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "deny" ]]
    jq -s -e 'length == 1 and .[0].harness == "codex" and .[0].action == "deny" and .[0].budget_type == "coder"' "$CLAUDE_TURN_BUDGET_LOG" >/dev/null
}

# ── A2b ── one constrained checkpoint over either hard ceiling ───────

@test "A2b: valid checkpoint write is allowed over the context-hard ceiling" {
    seed_usage_transcript s2b checkpoint1 "$((180000 + 1)):0:0"
    fire "$(checkpoint_event s2b checkpoint1 coder .cheese/handoff.md)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "checkpoint-write" ]]
    [[ "$(log_record | jq -r '.checkpointSpent')" == "true" ]]
    [[ -f "$CLAUDE_TURN_BUDGET_DIR/s2b/checkpoint1/checkpoint-spent" ]]
}

@test "A2b: a coder over the context ceiling may make a valid .context checkpoint" {
    seed_usage_transcript s2b checkpoint2 "$((180000 + 1)):0:0"
    fire "$(checkpoint_event s2b checkpoint2 coder .context/handoff.md)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.turns')" == "1" ]]
    [[ "$(log_record | jq -r '.reason')" == "checkpoint-write" ]]
}

@test "A2b: a create_file checkpoint for a new handoff note is allowed over the hard ceiling" {
    local json
    seed_usage_transcript s2b checkpoint_create "$((180000 + 1)):0:0"
    json=$(jq -nc --argjson event "$(checkpoint_event s2b checkpoint_create coder .cheese/notes/handoff.md)" \
        '$event | .tool_input.edits[0].ops = [{op:"create_file",content:"# handoff"}]')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "checkpoint-write" ]]
    [[ -f "$CLAUDE_TURN_BUDGET_DIR/s2b/checkpoint_create/checkpoint-spent" ]]
}

@test "A2b: a replace_text checkpoint is allowed over the context-hard ceiling" {
    local json
    seed_usage_transcript s2b checkpoint_replace_text "$((180000 + 1)):0:0"
    json=$(jq -nc --argjson event "$(checkpoint_event s2b checkpoint_replace_text coder .context/handoff.md)" \
        '$event | .tool_input.edits[0].ops = [{op:"replace_text",old:"todo",new:"done"}]')
    fire "$json"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "checkpoint-write" ]]
}

@test "A2b: hard-ceiling deny message names the allowed checkpoint ops" {
    seed_usage_transcript s2b checkpoint_msg "$((180000 + 1)):0:0"
    fire "$(pre_event s2b checkpoint_msg coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"create_file/replace_text/prepend/append/replace/insert_before/insert_after/replace_block/insert_after_block"* ]]
}

@test "A2c: SubagentHandback is allowed over the context-hard ceiling" {
    seed_usage_transcript s2c handback1 "$((180000 + 1)):0:0"
    fire "$(handback_event s2c handback1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "handback" ]]
}

@test "A2c: SubagentHandback is allowed over the context-hard ceiling after the checkpoint is spent" {
    seed_turns s2c handback2 5
    seed_usage_transcript s2c handback2 "$((180000 + 1)):0:0"
    fire "$(checkpoint_event s2c handback2 reviewer .cheese/notes.md)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(handback_event s2c handback2 reviewer)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(handback_event s2c handback2 reviewer)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(pre_event s2c handback2 reviewer)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"SubagentHandback stays allowed"* ]]
}

@test "A2d: StructuredOutput is allowed over the context-hard ceiling and other tools stay denied" {
    seed_usage_transcript s2d so_ctx "$((180000 + 1)):0:0"
    fire "$(structured_output_event s2d so_ctx coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "structured-output" ]]
    [[ "$(log_record | jq -r '.action')" == "allow" ]]
    fire "$(pre_event s2d so_ctx coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.reason')" == "hard-ceiling" ]]
}

@test "A2d: StructuredOutput is allowed at 500 turns with low context" {
    seed_turns s2d so_turn 500
    fire "$(structured_output_event s2d so_turn coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]
}

@test "A2b: a second valid checkpoint is denied after the allowance is spent" {
    seed_usage_transcript s2b checkpoint3 "$((180000 + 1)):0:0"
    fire "$(checkpoint_event s2b checkpoint3 coder .cheese/first.md)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(checkpoint_event s2b checkpoint3 coder .context/second.md)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"Stop calling tools now"* ]]
    [[ "$output" == *"checkpoint allowance is spent"* ]]
    [[ "$output" == *"return inline"* ]]
    [[ "$(log_record | jq -r '.checkpointSpent')" == "true" ]]
}

@test "A2b: an invalid checkpoint path is denied without spending the allowance" {
    seed_usage_transcript s2b checkpoint4 "$((180000 + 1)):0:0"
    fire "$(checkpoint_event s2b checkpoint4 coder notes/handoff.md)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"One mcp__tilth__tilth_write"* ]]
    [[ "$output" == *"No tool call is allowed except"* ]]
    [[ ! -f "$CLAUDE_TURN_BUDGET_DIR/s2b/checkpoint4/checkpoint-spent" ]]
    fire "$(checkpoint_event s2b checkpoint4 coder .cheese/handoff.md)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2b: multiple edits are denied without spending the allowance" {
    seed_usage_transcript s2b checkpoint5 "$((180000 + 1)):0:0"
    fire "$(multiple_checkpoint_event s2b checkpoint5 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ ! -f "$CLAUDE_TURN_BUDGET_DIR/s2b/checkpoint5/checkpoint-spent" ]]
}

@test "A2b: a resume already over hard is denied unless it is the valid checkpoint" {
    seed_usage_transcript s2b checkpoint6 "$((180000 + 1)):0:0"
    fire "$(pre_event s2b checkpoint6 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ ! -f "$CLAUDE_TURN_BUDGET_DIR/s2b/checkpoint6/checkpoint-spent" ]]
    fire "$(checkpoint_event s2b checkpoint6 coder .context/resume.md)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A2b: classifier only accepts content-writing ops for the exact tilth checkpoint" {
    local valid all_content_ops event_cwd process_cwd invalid_segment native_write alias other_tilth missing empty missing_ops empty_ops multiple mixed delete delete_block delete_file move_file move_outside mixed_destructive mixed_rename
    valid=$(checkpoint_event s2b classifier coder .cheese/handoff.md)
    all_content_ops=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops = [
        {op:"create_file",content:"checkpoint"},
        {op:"replace_text",old:"a",new:"b"},
        {op:"prepend",content:"checkpoint"},
        {op:"append",content:"checkpoint"},
        {op:"replace",start:1,end:1,content:"checkpoint"},
        {op:"insert_before",line:1,content:"checkpoint"},
        {op:"insert_after",line:1,content:"checkpoint"},
        {op:"replace_block",at:1,content:"checkpoint"},
        {op:"insert_after_block",at:1,content:"checkpoint"}
    ]')
    event_cwd=$(jq -nc --argjson event "$valid" --arg cwd "$PROJ/.context" \
        '$event | .tool_input |= del(.cwd) | .cwd = $cwd | .tool_input.edits[0].path = "handoff.md"')
    process_cwd=$(jq -nc --argjson event "$valid" \
        '$event | .tool_input |= del(.cwd) | del(.cwd) | .tool_input.edits[0].path = ".context/process.md"')
    invalid_segment=$(checkpoint_event s2b classifier coder .cheesecake/handoff.md)
    native_write=$(jq -nc --argjson event "$valid" '$event | .tool_name = "Write"')
    alias=$(jq -nc --argjson event "$valid" '$event | .tool_name = "cheez-write"')
    other_tilth=$(jq -nc --argjson event "$valid" '$event | .tool_name = "mcp__tilth__tilth_read"')
    missing=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits = [{}]')
    empty=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].path = ""')
    missing_ops=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0] |= del(.ops)')
    empty_ops=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops = []')
    multiple=$(multiple_checkpoint_event s2b classifier coder)
    mixed=$(jq -nc --argjson event "$multiple" '$event | .tool_input.edits[1].path = "notes/outside.md"')
    delete=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops = [{op:"delete",start:1,end:1}]')
    delete_block=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops = [{op:"delete_block",at:1}]')
    delete_file=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops = [{op:"delete_file"}]')
    move_file=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops = [{op:"move_file",dest:".context/moved.md"}]')
    move_outside=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops = [{op:"move_file",dest:"notes/moved.md"}]')
    mixed_destructive=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops += [{op:"delete_file"}]')
    mixed_rename=$(jq -nc --argjson event "$valid" '$event | .tool_input.edits[0].ops += [{op:"move_file",dest:"notes/moved.md"}]')
    run node -e 'const {isCheckpointWrite}=require(process.argv[1]); console.log(JSON.stringify(process.argv.slice(2).map((event) => isCheckpointWrite(JSON.parse(event)))));' \
        "$HOOK_JS" "$valid" "$all_content_ops" "$event_cwd" "$process_cwd" "$invalid_segment" "$native_write" "$alias" "$other_tilth" "$missing" "$empty" "$missing_ops" "$empty_ops" "$multiple" "$mixed" "$delete" "$delete_block" "$delete_file" "$move_file" "$move_outside" "$mixed_destructive" "$mixed_rename"
    assert_success
    [[ "$output" == "[true,true,true,true,false,false,false,false,false,false,false,false,false,false,false,false,false,false,false,false,false]" ]]
}

@test "A2b: concurrent valid checkpoints spend the allowance exactly once" {
    seed_usage_transcript s2b checkpoint7 "$((180000 + 1)):0:0"
    local json
    json=$(checkpoint_event s2b checkpoint7 coder .cheese/concurrent.md)
    printf '%s' "$json" | "$DEPLOY/hooks/turn-budget-guard.sh" > "$TEST_HOME/first.out" &
    local first=$!
    printf '%s' "$json" | "$DEPLOY/hooks/turn-budget-guard.sh" > "$TEST_HOME/second.out" &
    local second=$!
    wait "$first"
    wait "$second"
    [[ "$(jq -s 'map(select(.reason == "checkpoint-write")) | length' "$CLAUDE_TURN_BUDGET_LOG")" == "1" ]]
    [[ "$(jq -sr 'map(.action) | sort | join(",")' "$CLAUDE_TURN_BUDGET_LOG")" == "allow,deny" ]]
}

# ── A3 — soft nudge fires once ───────────────────────────────────────

@test "A3: PostToolUse crossing the soft context threshold nudges once, then never repeats" {
    seed_usage_transcript s3 c1 "$((150000 + 1)):0:0"  # > ctxSoft (150000)
    fire "$(post_event s3 c1 coder)"
    [[ "$(verdict)" == "nudge" ]]
    [[ "$output" == *"Do not stop yet"* ]]
    [[ "$output" != *"wrap up"* ]]
    [[ "$output" == *"hard ceiling 180000 context tokens"* ]]
    [[ "$output" != *"turns"* ]]
    [[ "$output" == *"return compact checkpoint observations inline"* ]]
    [[ "$output" == *"do not persist a checkpoint"* ]]
    [[ "$output" == *"non-checkpoint tool calls are hard-blocked"* ]]
    [[ "$output" == *"local guard budget"* ]]
    [[ "$output" == *"not a provider context failure"* ]]
    [[ "$output" == *"dispatch a fresh agent"* ]]

    # Marker set — a second PostToolUse must not nudge again.
    fire "$(post_event s3 c1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A3: non-coder soft nudge keeps blocker handoff guidance" {
    seed_usage_transcript s3 reviewer1 "$((150000 + 1)):0:0"
    fire "$(post_event s3 reviewer1 reviewer)"
    [[ "$(verdict)" == "nudge" ]]
    [[ "$output" == *"persist compact handoff observations"* ]]
    [[ "$output" == *"Do not stop yet"* ]]
    [[ "$output" == *"status: blocked: <reason>"* ]]
    [[ "$output" != *"status: needs-context"* ]]
}

@test "A3: nudge is logged once and later PostToolUse records already-nudged" {
    seed_usage_transcript s3 log3 "$((150000 + 1)):0:0"
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

@test "A3: context exactly at the soft threshold nudges" {
    seed_usage_transcript s3 c2 "150000:0:0"
    fire "$(post_event s3 c2 coder)"
    [[ "$(verdict)" == "nudge" ]]
}

# ── A3b ── hard nudge (context-hard ceiling, PostToolUse) ───────────

@test "A3b: hard nudge fires once on first crossing and suppresses the soft nudge too" {
    seed_turns s3b d1 1
    seed_usage_transcript s3b d1 "$((180000 + 1)):0:0"
    fire "$(post_event s3b d1 coder)"
    [[ "$(verdict)" == "nudge" ]]
    [[ "$output" == *"hard ceiling"* ]]
    [[ "$output" == *"mcp__tilth__tilth_write"* ]]
    [[ "$output" == *"status: needs-context"* ]]
    [[ "$output" == *"local guard budget"* ]]
    [[ "$output" == *"not a provider context failure"* ]]
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
    seed_usage_transcript s3b d2 "$((180000 + 1)):0:0"
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

# ── A5 — unknown agent_type -> same context budget ───────────────────

@test "A5: unknown agent_type is denied past the context hard ceiling" {
    seed_usage_transcript s5 e1 "$((180000 + 1)):0:0"
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A5: unknown agent_type at the context ceiling is allowed" {
    seed_usage_transcript s5 e1 "180000:0:0"
    fire "$(pre_event s5 e1 wizard)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A5: empty agent_type is reported as default" {
    seed_usage_transcript s5 e2 "$((180000 + 1)):0:0"
    fire "$(pre_event s5 e2 '')"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"type 'default'"* ]]
}

@test "A5b: general-purpose is allowed at 500 turns and denied only by context" {
    seed_turns s5b gp1 500
    seed_usage_transcript s5b gp1 "140000:0:0"
    fire "$(pre_event s5b gp1 general-purpose)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.budget_type')" == "general-purpose" ]]
}

@test "A5b: hard-ceiling deny tells the parent to dispatch a fresh agent, not resume" {
    seed_usage_transcript s5b fresh1 "$((180000 + 1)):0:0"
    fire "$(pre_event s5b fresh1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"dispatch a fresh agent"* ]]
    [[ "$output" == *"resuming this agent keeps its full context"* ]]
}

# ── A6 — independent counters + scoped cleanup ───────────────────────

@test "A6: distinct agent_ids under one session count independently" {
    seed_usage_transcript s6 f1 "180000:0:0"  # at the wall, still allowed
    seed_usage_transcript s6 f2 "$((180000 + 1)):0:0"
    fire "$(pre_event s6 f1 coder)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(pre_event s6 f2 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A6: same agent_id under distinct sessions counts independently" {
    # counterPath keys on BOTH session_id and agent_id. Two sub-agents that
    # share an agent_id across sessions must not collide on the checkpoint
    # marker: spending it in isoB must not spend it in isoA.
    seed_usage_transcript isoA z "$((180000 + 1)):0:0"
    seed_usage_transcript isoB z "$((180000 + 1)):0:0"
    fire "$(checkpoint_event isoB z coder .cheese/a.md)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(checkpoint_event isoA z coder .cheese/a.md)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "checkpoint-write" ]]
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
    seed_usage_transcript s7 logfail "$((180000 + 1)):0:0"
    fire "$(pre_event s7 logfail coder)"
    [[ "$(verdict)" == "deny" ]]
    jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$output" >/dev/null
}

# ── A7b ── Codex agent_transcript_path stat failure falls through ────

@test "A7b: failed agent_transcript_path stat falls through to the transcript walk" {
    seed_usage_transcript s7b g3 "$((180000 + 1)):0:0"  # over-hard, locatable via the walk
    local json
    json=$(jq -nc --arg s "s7b" --arg a "g3" --arg p "$PROJ/s7b.jsonl" --arg atp "$TEST_HOME/does-not-exist.jsonl" \
        '{hook_event_name:"PreToolUse", agent_id:$a, agent_type:"coder", session_id:$s, transcript_path:$p, agent_transcript_path:$atp, tool_name:"Bash", tool_input:{}}')
    fire "$json"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.tokens')" == "$((180000 + 1))" ]]
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

@test "B4: byte fallback that exceeds ctxHard on the token scale denies Bash" {
    # A transcript with no usage line and > 720000 bytes -> / 4 > 180000
    # tokens, so the fallback proxy must still enforce the hard ceiling.
    seed_turns s10 tok4 5
    seed_transcript s10 tok4 720004  # 720004 / 4 = 180001 > ctxHard
    fire "$(pre_event s10 tok4 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "bytes-fallback" ]]
    [[ "$(log_record | jq -r '.tokens')" == "180001" ]]
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

@test "B6: byte fallback allows the same constrained checkpoint exception" {
    seed_transcript s10 tok6 720004
    fire "$(checkpoint_event s10 tok6 coder .context/byte-fallback.md)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "checkpoint-write" ]]
    [[ "$(log_record | jq -r '.ctx_source')" == "bytes-fallback" ]]
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


# ── A12 ── fork baseline exemption ───────────────────────────────────

@test "A12: fork's first call, inherited context far above ctxHard, is allowed" {
    seed_turns s3 f1 5
    seed_usage_transcript s3 f1 "200000:0:0"  # above ctxHard (180000): only the fork baseline exemption allows this call
    fire "$(pre_event s3 f1 fork)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.budget_type')" == "fork" ]]
    [[ "$(log_record | jq -r '.tokens')" == "200000" ]]
    [[ "$(log_record | jq -r '.baseline')" == "200000" ]]
    [[ "$(log_record | jq -r '.charged_tokens')" == "0" ]]
    [[ "$(cat "$CLAUDE_TURN_BUDGET_DIR/s3/f1/baseline")" == "200000" ]]
}

@test "A12: fork is denied once its OWN accumulation past baseline exceeds ctxHard" {
    seed_turns s4 f2 5
    seed_usage_transcript s4 f2 "178791:0:0"
    fire "$(pre_event s4 f2 fork)"
    [[ "$(verdict)" == "allow" ]]

    seed_usage_transcript s4 f2 "$((178791 + 180001)):0:0"  # baseline + 180001 charged tokens
    fire "$(pre_event s4 f2 fork)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.baseline')" == "178791" ]]
    [[ "$(log_record | jq -r '.charged_tokens')" == "180001" ]]
}

@test "A12: a non-fork type (coder) at 180001 tokens is still denied — absolute path untouched" {
    seed_turns s5 c1 5
    seed_usage_transcript s5 c1 "180001:0:0"
    fire "$(pre_event s5 c1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$(log_record | jq -r '.charged_tokens')" == "180001" ]]
    [[ -z "$(log_record | jq -r '.baseline')" || "$(log_record | jq -r '.baseline')" == "null" ]]
}

@test "A12: fork's first call with an untrustworthy (source=none) reading does not poison the baseline" {
    seed_turns s6 f3 5
    # No transcript fixture written -> contextTokensFromEvent resolves to
    # tokens:0, source:'none'. An untrustworthy first reading must not
    # captureBaseline at 0, or the fork would be charged absolutely forever.
    fire "$(pre_event s6 f3 fork)"
    [[ "$(verdict)" == "allow" ]]
    [[ ! -e "$CLAUDE_TURN_BUDGET_DIR/s6/f3/baseline" ]]

    # A later, trustworthy (source='tokens') reading still establishes the
    # baseline -- even though the inherited figure alone exceeds ctxHard,
    # it is allowed because it becomes the baseline rather than being
    # compared against a stale/absent one.
    seed_usage_transcript s6 f3 "178791:0:0"
    fire "$(pre_event s6 f3 fork)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.baseline')" == "178791" ]]
    [[ "$(log_record | jq -r '.charged_tokens')" == "0" ]]
    [[ "$(cat "$CLAUDE_TURN_BUDGET_DIR/s6/f3/baseline")" == "178791" ]]
}

# ── A13 — no turn ceiling ────────────────────────────────────────────

@test "A13: coder at 500 turns with low context is allowed (no turn deny)" {
    seed_turns s13 g1 500
    seed_usage_transcript s13 g1 "10000:0:0"
    fire "$(pre_event s13 g1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "within-budget" ]]
    [[ "$(log_record | jq -r '.turns')" == "501" ]]
    [[ "$(log_record | jq -r '.turnHard')" == "null" ]]
}

@test "A13: unknown type at 500 turns with low context is allowed (no turn deny)" {
    seed_turns s13 g2 500
    seed_usage_transcript s13 g2 "10000:0:0"
    fire "$(pre_event s13 g2 wizard)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A13: PostToolUse at 500 turns with low context does not nudge" {
    seed_turns s13 g3 500
    seed_usage_transcript s13 g3 "10000:0:0"
    fire "$(post_event s13 g3 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "below-soft-threshold" ]]
}

# ── A14 — self-compacting agents are exempt ──────────────────────────

# Write an agent definition whose frontmatter carries `autoCompactWindow: N`.
write_agent_def() {
    local dir="$1" name="$2" window="$3"
    mkdir -p "$dir"
    printf -- '---\nname: %s\nautoCompactWindow: %s\n---\nbody\n' "$name" "$window" > "$dir/$name.md"
}

with_cwd() {
    jq -nc --argjson event "$1" --arg cwd "$2" '$event | .cwd = $cwd'
}

@test "A14: self-compacting coder over the hard ceiling is allowed on PreToolUse" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s14 sc1 "250000:0:0"
    fire "$(pre_event s14 sc1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$output" == "" ]]
    [[ "$(log_record | jq -r '.reason')" == "auto-compact" ]]
}

@test "A14: self-compacting coder over the hard ceiling gets no nudge on PostToolUse" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s14 sc2 "250000:0:0"
    fire "$(post_event s14 sc2 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$output" == "" ]]
    [[ "$(log_record | jq -r '.reason')" == "auto-compact" ]]
    [[ ! -f "$CLAUDE_TURN_BUDGET_DIR/s14/sc2/hard-nudged" ]]
}

@test "A14: the same type without a definition file is denied with the context ceiling message" {
    seed_usage_transcript s14 nd1 "250000:0:0"
    fire "$(pre_event s14 nd1 coder)"
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"context 250000/180000 tokens"* ]]
    [[ "$output" != *"turns"* ]]
}

@test "A14: a definition under <cwd>/.claude/agents also counts" {
    write_agent_def "$PROJ/.claude/agents" coder 150000
    seed_usage_transcript s14 cw1 "250000:0:0"
    fire "$(with_cwd "$(pre_event s14 cw1 coder)" "$PROJ")"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "auto-compact" ]]
}

@test "A14: a definition without the field does not exempt the agent" {
    mkdir -p "$HOME/.claude/agents"
    printf -- '---\nname: coder\n---\nautoCompactWindow: 150000\n' > "$HOME/.claude/agents/coder.md"
    seed_usage_transcript s14 nf1 "250000:0:0"
    fire "$(pre_event s14 nf1 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A14: a plugin-scoped agent_type is not self-compacting" {
    write_agent_def "$HOME/.claude/agents" milknado-worker 150000
    seed_usage_transcript s14 pl1 "250000:0:0"
    fire "$(pre_event s14 pl1 milknado:milknado-worker)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A14: a path-traversal agent_type is not self-compacting" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    mkdir -p "$HOME/.claude/agents/sub"
    seed_usage_transcript s14 tr1 "250000:0:0"
    fire "$(pre_event s14 tr1 ../coder)"
    [[ "$(verdict)" == "deny" ]]
    fire "$(pre_event s14 tr1 sub/../coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A14: an out-of-range autoCompactWindow is not self-compacting" {
    write_agent_def "$HOME/.claude/agents" coder 50000
    seed_usage_transcript s14 rg1 "250000:0:0"
    fire "$(pre_event s14 rg1 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A14: a self-compacting agent's SubagentStop still cleans up its counter dir" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    fire "$(pre_event s14 sc3 coder)"
    [[ -d "$CLAUDE_TURN_BUDGET_DIR/s14/sc3" ]]
    fire "$(jq -nc '{hook_event_name:"SubagentStop", agent_id:"sc3", agent_type:"coder", session_id:"s14"}')"
    [[ ! -d "$CLAUDE_TURN_BUDGET_DIR/s14/sc3" ]]
}

@test "A14: workflow-subagent keeps the context ceiling" {
    seed_usage_transcript s14 w1 "180001:0:0"
    fire "$(pre_event s14 w1 workflow-subagent)"
    [[ "$(verdict)" == "deny" ]]
}

# ── A15 — frontmatter / name / path edge cases for the exemption ─────

# Write raw definition bytes (backslash escapes expanded) to $HOME/.claude/agents/<name>.md,
# then fire PreToolUse for <name> past the hard ceiling; leaves verdict in $output.
fire_with_raw_def() {
    local name="$1" raw="$2" session="${3:-s15}" agent="${4:-r1}"
    mkdir -p "$HOME/.claude/agents"
    printf '%b' "$raw" > "$HOME/.claude/agents/$name.md"
    seed_usage_transcript "$session" "$agent" "250000:0:0"
    fire "$(pre_event "$session" "$agent" "$name")"
}

@test "A15: CRLF frontmatter with a valid window is exempt" {
    fire_with_raw_def coder '---\r\nname: coder\r\nautoCompactWindow: 150000\r\n---\r\nbody\r\n'
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "auto-compact" ]]
}

@test "A15: quoted autoCompactWindow is not exempt (strict integer only)" {
    fire_with_raw_def coder '---\nname: coder\nautoCompactWindow: "150000"\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: autoCompactWindow with a trailing YAML comment is not exempt" {
    # speculative: valid YAML, but the guard's strict regex rejects it (fails toward the ceiling)
    fire_with_raw_def coder '---\nname: coder\nautoCompactWindow: 150000 # tuned\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: indented autoCompactWindow key is not exempt" {
    fire_with_raw_def coder '---\nname: coder\n  autoCompactWindow: 150000\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: window of exactly 100000 is exempt" {
    fire_with_raw_def coder '---\nautoCompactWindow: 100000\n---\n'
    [[ "$(verdict)" == "allow" ]]
}

@test "A15: window of exactly 1000000 is exempt" {
    fire_with_raw_def coder '---\nautoCompactWindow: 1000000\n---\n'
    [[ "$(verdict)" == "allow" ]]
}

@test "A15: window of 99999 is not exempt" {
    fire_with_raw_def coder '---\nautoCompactWindow: 99999\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: window of 1000001 is not exempt" {
    fire_with_raw_def coder '---\nautoCompactWindow: 1000001\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: negative and decimal windows are not exempt" {
    fire_with_raw_def coder '---\nautoCompactWindow: -150000\n---\n'
    [[ "$(verdict)" == "deny" ]]
    fire_with_raw_def coder '---\nautoCompactWindow: 150000.5\n---\n' s15 r2
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: field only in a second frontmatter block is not exempt" {
    fire_with_raw_def coder '---\nname: coder\n---\n---\nautoCompactWindow: 150000\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: file without an opening --- fence is not exempt" {
    fire_with_raw_def coder 'name: coder\nautoCompactWindow: 150000\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: unterminated frontmatter that still carries the field is exempt" {
    # speculative: documents current behavior (no closing fence required)
    fire_with_raw_def coder '---\nautoCompactWindow: 150000\n'
    [[ "$(verdict)" == "allow" ]]
}

@test "A15: UTF-8 BOM before the opening fence is not exempt" {
    # speculative: documents fail-toward-ceiling on BOM-prefixed files
    fire_with_raw_def coder '\xef\xbb\xbf---\nautoCompactWindow: 150000\n---\n'
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: empty definition file is not exempt" {
    fire_with_raw_def coder ''
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: definition path that is a directory is not exempt and does not crash" {
    mkdir -p "$HOME/.claude/agents/coder.md"
    seed_usage_transcript s15 d1 "250000:0:0"
    fire "$(pre_event s15 d1 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: definition that is a symlink to a valid file is exempt" {
    mkdir -p "$HOME/.claude/agents" "$TEST_HOME/elsewhere"
    printf -- '---\nautoCompactWindow: 150000\n---\n' > "$TEST_HOME/elsewhere/real.md"
    ln -s "$TEST_HOME/elsewhere/real.md" "$HOME/.claude/agents/coder.md"
    seed_usage_transcript s15 l1 "250000:0:0"
    fire "$(pre_event s15 l1 coder)"
    [[ "$(verdict)" == "allow" ]]
}

@test "A15: dangling symlink definition is not exempt" {
    mkdir -p "$HOME/.claude/agents"
    ln -s "$TEST_HOME/nope.md" "$HOME/.claude/agents/coder.md"
    seed_usage_transcript s15 l2 "250000:0:0"
    fire "$(pre_event s15 l2 coder)"
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: uppercase agent_type (Explore) resolves to Explore.md and is exempt" {
    write_agent_def "$HOME/.claude/agents" Explore 150000
    seed_usage_transcript s15 u1 "250000:0:0"
    fire "$(pre_event s15 u1 Explore)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "auto-compact" ]]
}

@test "A15: agent_type with a space is not exempt" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    cp "$HOME/.claude/agents/coder.md" "$HOME/.claude/agents/my coder.md"
    seed_usage_transcript s15 sp1 "250000:0:0"
    fire "$(pre_event s15 sp1 'my coder')"
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: empty agent_type is not exempt" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s15 e1 "250000:0:0"
    fire "$(pre_event s15 e1 '')"
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: agent_type with a trailing newline is not exempt" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s15 nl1 "250000:0:0"
    fire "$(pre_event s15 nl1 coder | jq -c '.agent_type = "coder\n"')"
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: nonexistent cwd falls back to the HOME definition" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s15 c1 "250000:0:0"
    fire "$(with_cwd "$(pre_event s15 c1 coder)" "$TEST_HOME/does/not/exist")"
    [[ "$(verdict)" == "allow" ]]
}

@test "A15: relative cwd does not crash and HOME definition still exempts" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s15 c2 "250000:0:0"
    fire "$(with_cwd "$(pre_event s15 c2 coder)" "relative/dir")"
    [[ "$(verdict)" == "allow" ]]
}

@test "A15: non-string cwd does not crash and a missing definition is denied" {
    seed_usage_transcript s15 c3 "250000:0:0"
    fire "$(pre_event s15 c3 coder | jq -c '.cwd = 42')"
    [[ "$(verdict)" == "deny" ]]
}

@test "A15: invalid cwd definition still exempts via a valid HOME definition" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    write_agent_def "$PROJ/.claude/agents" coder 50000
    seed_usage_transcript s15 c4 "250000:0:0"
    fire "$(with_cwd "$(pre_event s15 c4 coder)" "$PROJ")"
    [[ "$(verdict)" == "allow" ]]
    [[ "$(log_record | jq -r '.reason')" == "auto-compact" ]]
}

@test "A15: valid cwd definition still exempts when the HOME definition is invalid" {
    write_agent_def "$HOME/.claude/agents" coder 50000
    write_agent_def "$PROJ/.claude/agents" coder 150000
    seed_usage_transcript s15 c5 "250000:0:0"
    fire "$(with_cwd "$(pre_event s15 c5 coder)" "$PROJ")"
    [[ "$(verdict)" == "allow" ]]
}

@test "A15: exempt agent in the soft zone (160k) gets no soft nudge on PreToolUse or PostToolUse" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s15 z1 "160000:0:0"
    fire "$(pre_event s15 z1 coder)"
    [[ "$(verdict)" == "allow" ]]
    fire "$(post_event s15 z1 coder)"
    [[ "$(verdict)" == "allow" ]]
    [[ "$output" == "" ]]
    [[ ! -f "$CLAUDE_TURN_BUDGET_DIR/s15/z1/nudged" ]]
    [[ ! -f "$CLAUDE_TURN_BUDGET_DIR/s15/z1/hard-nudged" ]]
}

@test "A15: exempt agent at 1M context never hard-nudges across repeated PostToolUse" {
    write_agent_def "$HOME/.claude/agents" coder 150000
    seed_usage_transcript s15 z2 "1000000:0:0"
    local _
    for _ in 1 2 3; do
        fire "$(post_event s15 z2 coder)"
        [[ "$output" == "" ]]
    done
    [[ ! -f "$CLAUDE_TURN_BUDGET_DIR/s15/z2/hard-nudged" ]]
}

@test "A15: definition lacking the field still hard-denies past 180k with the context message" {
    fire_with_raw_def coder '---\nname: coder\n---\n'
    [[ "$(verdict)" == "deny" ]]
    [[ "$output" == *"context 250000/180000 tokens"* ]]
}
