#!/usr/bin/env bats
# Native Claude and Codex transcript checks for the shared wheypoint policy.
load test_helper
bats_require_minimum_version 1.5.0

HOOK="$REAL_DOTFILES_DIR/agents/hooks/wheypoint-stop-gate.sh"

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v git >/dev/null 2>&1 || skip "git not installed"
    REPO="$TEST_HOME/repo"
    TRANSCRIPT="$TEST_HOME/transcript.jsonl"
    : >"$TRANSCRIPT"
    mkdir -p "$REPO"
    (
        cd "$REPO" || return 1
        git init --quiet
        git config user.email "test@example.com"
        git config user.name "Test User"
        echo code >code.txt
        git add code.txt
        git commit -m "init" --quiet
    )
}
teardown() { teardown_test_env; }

# Append a native tool call and its result.
tool_use() {
    local id result=ok
    id="call-$(wc -l <"$TRANSCRIPT")"
    [[ "$1" == Bash && "$2" == *wheypoint.pyz*checkpoint* ]] && result='{"ok":true,"command":"checkpoint"}'
    jq -cn --arg n "$1" --argjson i "$2" --arg id "$id" \
        '{type:"assistant",sessionId:"session",message:{content:[{type:"tool_use",id:$id,name:$n,input:$i}]}}' >>"$TRANSCRIPT"
    jq -cn --arg id "$id" --arg result "$result" \
        '{type:"user",sessionId:"session",message:{content:[{type:"tool_result",tool_use_id:$id,content:$result,is_error:false}]}}' >>"$TRANSCRIPT"
}

# $1=text
say() {
    jq -cn --arg t "$1" \
        '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' \
        >>"$TRANSCRIPT"
}

user_says() {
    jq -cn --arg t "$1" \
        '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' \
        >>"$TRANSCRIPT"
}

# The sandbox lives under /tmp, which the gate ignores, so edits name a path
# outside /tmp. The gate never opens the edited file.
edit_repo_file() { tool_use Edit '{"file_path":"/work/repo/code.txt"}'; }
dirty_tree() { echo change >>"$REPO/code.txt"; }

# $1=stop_hook_active (default false)
stop_payload() {
    jq -cn --arg t "$TRANSCRIPT" --arg c "$REPO" --argjson a "${1:-false}" \
        '{transcript_path:$t,cwd:$c,stop_hook_active:$a}'
}

run_gate() { run bash "$HOOK" <<<"$(stop_payload "$@")"; }

assert_silent() {
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── Silent: nothing in progress ─────────────────────────────────────────────

@test "silent on a Q&A session with no file change" {
    user_says "how long before it fires?"
    tool_use Bash '{"command":"ls"}'
    say "It fires at once."
    run_gate
    assert_silent
}

@test "silent when the file change is committed and no wheypoint exists" {
    edit_repo_file
    (cd "$REPO" && echo change >>code.txt && git commit -aqm work)
    run_gate
    assert_silent
}

@test "silent when a checkpoint came after the last file change" {
    edit_repo_file
    dirty_tree
    tool_use Bash '{"command":"python3 wheypoint.pyz checkpoint"}'
    run_gate
    assert_silent
}

@test "Skill call does not clear a pending edit" {
    edit_repo_file
    dirty_tree
    tool_use Skill '{"skill":"wheypoint"}'
    run_gate
    [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "silent for writes under /tmp and .cheese" {
    dirty_tree
    tool_use Write '{"file_path":"/tmp/intent.json"}'
    tool_use Edit '{"file_path":"/work/repo/.cheese/notes/x.md"}'
    tool_use mcp__tilth__tilth_write '{"edits":[{"path":"/tmp/a.json","ops":[]}]}'
    run_gate
    assert_silent
}

@test "silent when a user message quotes the wheypoint marker" {
    user_says "Wheypoint dropped: [note](/tmp/note.md)"
    run_gate
    assert_silent
}

# ── Blocks: work in progress ────────────────────────────────────────────────

@test "blocks with a write request when files changed and the tree is dirty" {
    edit_repo_file
    dirty_tree
    run_gate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == "Work is uncommitted. Write a wheypoint"* ]]
}

@test "blocks with an update request after a verified checkpoint" {
    tool_use Bash '{"command":"python3 wheypoint.pyz checkpoint"}'
    edit_repo_file
    run_gate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
    [[ "$(jq -r '.reason' <<<"$output")" == "Update this session's wheypoint"* ]]
}

@test "a dirty tree without a file change in the transcript does not block" {
    dirty_tree
    say "Nothing edited this session."
    run_gate
    assert_silent
}

@test "blocks on a tilth_write to a repo path" {
    tool_use Bash '{"command":"python3 wheypoint.pyz checkpoint"}'
    tool_use mcp__tilth__tilth_write '{"edits":[{"path":"/work/repo/code.txt","ops":[]}]}'
    run_gate
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "blocks on a git commit with options after the checkpoint" {
    tool_use Bash '{"command":"python3 wheypoint.pyz checkpoint"}'
    tool_use Bash '{"command":"cd x && git -C repo -c user.name=x commit -m msg"}'
    run_gate
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "does not treat git status or git log as a change" {
    say "Wheypoint dropped: [note](/tmp/note.md)"
    tool_use Bash '{"command":"git status && git log --oneline"}'
    run_gate
    assert_silent
}

@test "quoted shell text does not count as a git mutation" {
    tool_use Bash '{"command":"python3 wheypoint.pyz checkpoint"}'
    tool_use Bash '{"command":"echo git commit"}'
    dirty_tree
    run_gate
    assert_silent
}

# ── Guards and fail-open ────────────────────────────────────────────────────

@test "silent when stop_hook_active is true" {
    edit_repo_file
    dirty_tree
    run_gate true
    assert_silent
}

@test "silent when WHEYPOINT_STOP_GATE=0" {
    edit_repo_file
    dirty_tree
    run env WHEYPOINT_STOP_GATE=0 bash "$HOOK" <<<"$(stop_payload)"
    assert_silent
}

@test "silent when the transcript is missing" {
    rm "$TRANSCRIPT"
    run_gate
    assert_silent
}

@test "empty or invalid stdin does not write stdout" {
    run --separate-stderr bash "$HOOK" <<<""
    assert_silent
    run --separate-stderr bash "$HOOK" <<<"not json"
    assert_silent
}

@test "skips malformed transcript lines" {
    echo "{broken" >>"$TRANSCRIPT"
    edit_repo_file
    dirty_tree
    run_gate
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}

@test "quoted marker cannot clear a pending edit" {
    edit_repo_file
    say "The user quoted: Wheypoint dropped: [quoted](/tmp/note.md)"
    dirty_tree
    run_gate
    [ "$status" -eq 0 ]
    [ "$(jq -r '.decision' <<<"$output")" = "block" ]
}


@test "failed edit result stays silent despite a dirty tree" {
    jq -cn '{type:"assistant",sessionId:"session",message:{content:[{type:"tool_use",id:"failed",name:"Edit",input:{file_path:"code.txt"}}]}}' >>"$TRANSCRIPT"
    jq -cn '{type:"user",sessionId:"session",message:{content:[{type:"tool_result",tool_use_id:"failed",content:"failed",is_error:true}]}}' >>"$TRANSCRIPT"
    dirty_tree
    run_gate
    assert_silent
}

@test "Codex native successful and failed results are correlated" {
    {
        jq -cn '{type:"session_meta",payload:{id:"session"}}'
        jq -cn '{type:"response_item",payload:{type:"function_call",call_id:"bad",name:"mcp__tilth__tilth_write",arguments:"{\"edits\":[{\"path\":\"code.txt\"}]}"}}'
        jq -cn '{type:"response_item",payload:{type:"function_call_output",call_id:"bad",output:{isError:true}}}'
    } >>"$TRANSCRIPT"
    dirty_tree
    run_gate
    assert_silent
    {
        jq -cn '{type:"response_item",payload:{type:"function_call",call_id:"good",name:"mcp__tilth__tilth_write",arguments:"{\"edits\":[{\"path\":\"code.txt\"}]}"}}'
        jq -cn '{type:"response_item",payload:{type:"function_call_output",call_id:"good",output:{isError:false}}}'
    } >>"$TRANSCRIPT"
    run_gate
    [ "$(jq -r .decision <<<"$output")" = block ]
}

# Codex PostToolUse observes nested code-mode calls with the native hook input.
codex_post() {
    run --separate-stderr env DOTFILES_HARNESS=codex TMPDIR="$TEST_HOME" bash "$HOOK" <<<"$1"
}
codex_stop() {
    run --separate-stderr env DOTFILES_HARNESS=codex TMPDIR="$TEST_HOME" bash "$HOOK" \
        <<<"$(jq -cn --arg c "$REPO" '{hook_event_name:"Stop",session_id:"parent",cwd:$c}')"
}

@test "Codex PostToolUse records a successful nested Tilth write for its parent" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"write-1","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"}]},"tool_response":{"isError":false,"content":[{"type":"text","text":"applied"}]}}'
    assert_silent
    dirty_tree
    codex_stop
    [ "$(jq -r .decision <<<"$output")" = block ]
    [[ "$(jq -r .reason <<<"$output")" == "Work is uncommitted"* ]]
}

@test "Codex PostToolUse ignores failed nested calls" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"write-1","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"}]},"tool_response":{"isError":true}}'
    assert_silent
    dirty_tree
    codex_stop
    assert_silent
}

@test "Codex child PostToolUse checkpoint resets parent state" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"write-1","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"}]},"tool_response":{"isError":false}}'
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"checkpoint-1","tool_name":"Bash","tool_input":{"command":"python3 wheypoint.pyz checkpoint"},"tool_response":{"exit_code":0,"output":"{\"ok\":true,\"command\":\"checkpoint\"}"}}'
    dirty_tree
    codex_stop
    assert_silent
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"write-2","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"}]},"tool_response":{"isError":false}}'
    codex_stop
    [ "$(jq -r .decision <<<"$output")" = block ]
    [[ "$(jq -r .reason <<<"$output")" == "Update this session"* ]]
}

@test "Codex observer rejects quoted, replayed, and failed checkpoints" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"write-1","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"}]},"tool_response":{"isError":false}}'
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"checkpoint-1","tool_name":"Bash","tool_input":{"command":"python3 wheypoint.pyz checkpoint"},"tool_response":{"exit_code":0,"output":"{\"ok\":true,\"command\":\"checkpoint\",\"replayed\":true}"}}'
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"checkpoint-2","tool_name":"Bash","tool_input":{"command":"python3 wheypoint.pyz checkpoint"},"tool_response":{"exit_code":1,"output":"{\"ok\":true,\"command\":\"checkpoint\"}"}}'
    dirty_tree
    codex_stop
    [ "$(jq -r .decision <<<"$output")" = block ]
    [[ "$(jq -r .reason <<<"$output")" == "Work is uncommitted"* ]]
}

@test "registry deploys both gate hooks and shared assets" {
    local entry
    entry=$(yq -o=json '.hooks."wheypoint-stop-gate-observe"' "$REAL_DOTFILES_DIR/agents/hooks/registry.yaml")
    [ "$(jq -r .event <<<"$entry")" = PostToolUse ]
    [ "$(jq -r '.harnesses[0]' <<<"$entry")" = codex ]
    [ "$(jq -r '.shared_assets | length' <<<"$entry")" -eq 2 ]
    [[ "$(jq -r .matcher <<<"$entry")" == *tilth_write* ]]
}

@test "Claude includes only linked child mutations in timestamp order" {
    mkdir -p "$TEST_HOME/session/subagents"
    jq -cn '{type:"assistant",sessionId:"session",timestamp:"2026-10-11T00:00:00Z",message:{content:[{type:"tool_use",id:"agent-1",name:"Agent",input:{prompt:"edit"}}]}}' >>"$TRANSCRIPT"
    jq -cn '{type:"assistant",sessionId:"child",timestamp:"2026-10-11T00:00:01Z",message:{content:[{type:"tool_use",id:"child-edit",name:"Edit",input:{file_path:"code.txt"}}]}}' >"$TEST_HOME/session/subagents/linked.jsonl"
    jq -cn '{type:"user",sessionId:"child",timestamp:"2026-10-11T00:00:02Z",message:{content:[{type:"tool_result",tool_use_id:"child-edit",content:"ok",is_error:false}]}}' >>"$TEST_HOME/session/subagents/linked.jsonl"
    jq -cn '{toolUseId:"agent-1",agentType:"coder"}' >"$TEST_HOME/session/subagents/linked.meta.json"
    jq -cn '{type:"assistant",sessionId:"other",timestamp:"2026-10-11T00:00:03Z",message:{content:[{type:"tool_use",id:"other-edit",name:"Edit",input:{file_path:"code.txt"}}]}}' >"$TEST_HOME/session/subagents/unlinked.jsonl"
    jq -cn '{type:"user",sessionId:"other",timestamp:"2026-10-11T00:00:04Z",message:{content:[{type:"tool_result",tool_use_id:"other-edit",content:"ok",is_error:false}]}}' >>"$TEST_HOME/session/subagents/unlinked.jsonl"
    jq -cn '{toolUseId:"unrelated-agent",agentType:"coder"}' >"$TEST_HOME/session/subagents/unlinked.meta.json"
    dirty_tree
    run_gate
    [ "$(jq -r .decision <<<"$output")" = block ]
    rm "$TEST_HOME/session/subagents/linked.jsonl" "$TEST_HOME/session/subagents/linked.meta.json"
    run_gate
    assert_silent
}

@test "Codex observer never stores transcript content in its journal" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"write-secret","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"}]},"tool_response":{"isError":false,"content":[{"type":"text","text":"secret-content"}]}}'
    assert_silent
    local journal
    journal=$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update("parent").digest("hex"))')
    run grep -q secret-content "$TEST_HOME/wheypoint-stop-gate/$journal.jsonl"
    [ "$status" -ne 0 ]
}

@test "Codex observer ignores relative artifact paths" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"artifact","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"./.cheese/report.md"}]},"tool_response":{"isError":false}}'
    dirty_tree
    codex_stop
    assert_silent
}

@test "relative tmp is not an ignored system temp path" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"repo-tmp","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"tmp/code.txt"}]},"tool_response":{"isError":false}}'
    dirty_tree
    codex_stop
    [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "partial Tilth failure counts only a successful tracked section" {
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"failed-part","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"},{"path":".cheese/report.md"}]},"tool_response":{"isError":false,"content":[{"type":"text","text":"## code.txt\nerror: Edit rejected\n\n## .cheese/report.md\napplied\n"}]}}'
    dirty_tree
    codex_stop
    assert_silent
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"good-part","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"},{"path":".cheese/report.md"}]},"tool_response":{"isError":false,"content":[{"type":"text","text":"## code.txt\napplied\n\n## .cheese/report.md\nerror: Edit rejected\n"}]}}'
    codex_stop
    [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "evaluation errors keep stdout empty and report bounded context" {
    edit_repo_file
    dirty_tree
    run --separate-stderr bash "$HOOK" <<<"$(jq -cn --arg t "$TRANSCRIPT" '{transcript_path:$t,cwd:"/missing/repo",session_id:"private-secret"}')"
    assert_silent
    [[ "$stderr" == wheypoint-stop-gate:* ]]
    [[ "$stderr" != *private-secret* ]]
    [[ "$stderr" != *code.txt* ]]
}

@test "Codex checkpoint accepts pretty JSON in unified exec final output" {
    local reply
    reply=$'Wall time: 0.1 seconds\nProcess exited with code 0\nFinal output:\n{\n  "ok": true,\n  "command": "checkpoint",\n  "work_id": "work-1",\n  "revision_id": "rev-1",\n  "revision_number": 2,\n  "projection_path": "/tmp/note.md"\n}'
    codex_post "$(jq -cn --arg reply "$reply" '{hook_event_name:"PostToolUse",session_id:"parent",tool_use_id:"checkpoint-pretty",tool_name:"Bash",tool_input:{command:"python3 wheypoint.pyz checkpoint"},tool_response:{exit_code:0,output:$reply}}')"
    codex_post '{"hook_event_name":"PostToolUse","session_id":"parent","tool_use_id":"edit-after","tool_name":"mcp__tilth__tilth_write","tool_input":{"edits":[{"path":"code.txt"}]},"tool_response":{"isError":false}}'
    codex_stop
    [ "$(jq -r .decision <<<"$output")" = block ]
    [[ "$(jq -r .reason <<<"$output")" == "Update this session"* ]]
}

@test "stringified Tilth wrapper does not count a failed tracked section" {
    local text response
    text=$'## code.txt\nerror: Edit rejected\n\n## .cheese/report.md\napplied\n'
    response=$(jq -cn --arg text "$text" '{isError:false,content:[{type:"text",text:$text}]}')
    codex_post "$(jq -cn --arg response "$response" '{hook_event_name:"PostToolUse",session_id:"parent",tool_use_id:"stringified-part",tool_name:"mcp__tilth__tilth_write",tool_input:{edits:[{path:"code.txt"},{path:".cheese/report.md"}]},tool_response:$response}')"
    dirty_tree
    codex_stop
    assert_silent
}

@test "Claude checkpoint after linked child edit clears chronological work" {
    mkdir -p "$TEST_HOME/session/subagents"
    {
        jq -cn '{type:"assistant",sessionId:"session",timestamp:"2026-10-11T00:00:00Z",message:{content:[{type:"tool_use",id:"agent-1",name:"Agent",input:{prompt:"edit"}}]}}'
        jq -cn '{type:"assistant",sessionId:"session",timestamp:"2026-10-11T00:00:03Z",message:{content:[{type:"tool_use",id:"checkpoint",name:"Bash",input:{command:"python3 wheypoint.pyz checkpoint"}}]}}'
        jq -cn '{type:"user",sessionId:"session",timestamp:"2026-10-11T00:00:04Z",message:{content:[{type:"tool_result",tool_use_id:"checkpoint",content:"{\"ok\":true,\"command\":\"checkpoint\"}",is_error:false}]}}'
    } >>"$TRANSCRIPT"
    jq -cn '{type:"assistant",sessionId:"child",timestamp:"2026-10-11T00:00:01Z",message:{content:[{type:"tool_use",id:"child-edit",name:"Edit",input:{file_path:"code.txt"}}]}}' >"$TEST_HOME/session/subagents/linked.jsonl"
    jq -cn '{type:"user",sessionId:"child",timestamp:"2026-10-11T00:00:02Z",message:{content:[{type:"tool_result",tool_use_id:"child-edit",content:"ok",is_error:false}]}}' >>"$TEST_HOME/session/subagents/linked.jsonl"
    jq -cn '{toolUseId:"agent-1"}' >"$TEST_HOME/session/subagents/linked.meta.json"
    dirty_tree
    run_gate
    assert_silent
}

@test "Claude user string content does not hide a later successful edit" {
    jq -cn '{type:"user",sessionId:"session",message:{content:"plain user text"}}' >>"$TRANSCRIPT"
    edit_repo_file
    dirty_tree
    run --separate-stderr bash "$HOOK" <<<"$(stop_payload)"
    [ "$status" -eq 0 ]
    [ "$(jq -r .decision <<<"$output")" = block ]
}

@test "invalid nonempty hook input reports bounded stderr" {
    run --separate-stderr bash "$HOOK" <<<"not json"
    assert_silent
    [[ "$stderr" == wheypoint-stop-gate:* ]]
    [[ "$stderr" != *"not json"* ]]
}
