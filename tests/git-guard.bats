#!/usr/bin/env bats
# Tests for the git-guard PreToolUse hook (harness-agnostic).
#   agents/hooks/git-guard.sh   — bash bridge (self-locating, Claude/Codex)
#   agents/lib/git-guard.js     — classifier + dirty-tree gate + deny decision
#   cursor/.../hooks/git-guard.sh        — Cursor beforeShellExecution adapter
#   chezmoi/.../hooks/executable_git-guard.sh — Copilot preToolUse adapter
#
# WHY each branch is tested: `git checkout -- file` (and friends) reset the
# WHOLE working-tree file to HEAD with no recovery. The guard's entire value
# is (a) catching every destructive verb form an agent might emit, including
# sudo/env-prefixed and `-C`/`-c`-decorated invocations, AND (b) ONLY blocking
# when the targeted paths are actually dirty — a guard that nags on a clean
# tree gets disabled, and a guard that misses the dirty case fails its job.
# The fail-open tests encode the rule that a broken guard must never block.

load test_helper

HOOK_SH="$REAL_DOTFILES_DIR/agents/hooks/git-guard.sh"
HOOK_JS="$REAL_DOTFILES_DIR/agents/lib/git-guard.js"
CURSOR_HOOK="$REAL_DOTFILES_DIR/cursor/plugins/local/cheese-grok/hooks/git-guard.sh"
COPILOT_HOOK="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/hooks/executable_git-guard.sh"

setup() {
    setup_test_env
    # Mirror the deployed layout for the Claude/Codex bridge:
    #   <root>/hooks/<bridge> + <root>/lib/<logic>.
    DEPLOY="$TEST_HOME/.claude"
    mkdir -p "$DEPLOY/hooks" "$DEPLOY/lib"
    cp "$HOOK_SH" "$DEPLOY/hooks/git-guard.sh"
    cp "$HOOK_JS" "$DEPLOY/lib/git-guard.js"
    chmod +x "$DEPLOY/hooks/git-guard.sh"

    # A real repo with one committed file, then a dirty working-tree edit.
    REPO="$TEST_HOME/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email t@t.test
    git -C "$REPO" config user.name "T"
    printf 'v1\n' > "$REPO/tracked.txt"
    printf 'other\n' > "$REPO/second.txt"
    git -C "$REPO" add tracked.txt second.txt
    git -C "$REPO" commit -qm init
}

teardown() {
    teardown_test_env
}

# Make the working tree dirty in tracked.txt only.
dirty_tracked() { printf 'uncommitted edit\n' >> "$REPO/tracked.txt"; }
# Drop an untracked file (relevant for `git clean -f`).
add_untracked() { printf 'junk\n' > "$REPO/untracked.txt"; }
# Commit a path whose name contains a space, then dirty it — exercises the
# quote/escape-aware tokenizer (a naive whitespace split mismapped it).
dirty_spaced() {
    printf 'orig\n' > "$REPO/has space.txt"
    git -C "$REPO" add "has space.txt"
    git -C "$REPO" commit -qm 'add spaced file'
    printf 'uncommitted\n' >> "$REPO/has space.txt"
}

# Feed a PreToolUse event to the Claude/Codex bridge; echo deny|allow.
guard() {
    local tool="$1" cmd="$2"
    local json
    json=$(jq -nc --arg t "$tool" --arg c "$cmd" --arg w "$REPO" \
        '{tool_name:$t, tool_input:{command:$c}, cwd:$w}')
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/git-guard.sh'"
    [ "$status" -eq 0 ]
    if [[ -z "$output" ]]; then echo "allow"; else
        jq -r '.hookSpecificOutput.permissionDecision' <<<"$output"
    fi
}

# ── destructive verbs, dirty tree → deny ──────────────────────────────

@test "checkout -- <path> on a dirty file is denied" {
    dirty_tracked
    [[ "$(guard Bash 'git checkout -- tracked.txt')" == "deny" ]]
}

@test "checkout . on a dirty tree is denied" {
    dirty_tracked
    [[ "$(guard Bash 'git checkout .')" == "deny" ]]
}

@test "checkout -f on a dirty tree is denied" {
    dirty_tracked
    [[ "$(guard Bash 'git checkout -f')" == "deny" ]]
}

@test "restore <path> on a dirty file is denied" {
    dirty_tracked
    [[ "$(guard Bash 'git restore tracked.txt')" == "deny" ]]
}

@test "reset --hard on a dirty tree is denied" {
    dirty_tracked
    [[ "$(guard Bash 'git reset --hard')" == "deny" ]]
}

@test "clean -f with an untracked file is denied" {
    add_untracked
    [[ "$(guard Bash 'git clean -fd')" == "deny" ]]
}

# ── quoting / escaping: pathspecs must still map to `git status` ───────
# Regression: a naive whitespace split turned `git checkout -- "a b.txt"`
# into pathspecs '"a' 'b.txt"' that matched no file, so the dirty check
# came back clean and the guard failed OPEN. The tokenizer now strips
# quotes/escapes before building the pathspec.

@test "checkout -- quoted path with spaces (dirty) is denied" {
    dirty_spaced
    [[ "$(guard Bash 'git checkout -- "has space.txt"')" == "deny" ]]
}

@test "checkout -- backslash-escaped path with spaces (dirty) is denied" {
    dirty_spaced
    [[ "$(guard Bash 'git checkout -- has\ space.txt')" == "deny" ]]
}

@test "quoted shell operator inside env does not hide a dirty reset --hard" {
    dirty_tracked
    [[ "$(guard Bash 'env GIT_PAGER="cat | less" git reset --hard')" == "deny" ]]
}

# ── the gate: clean tree / non-destructive → allow ─────────────────────

@test "checkout -- <path> on a CLEAN file is allowed (nothing to lose)" {
    # tracked.txt is clean (only setup commit); no nagging.
    [[ "$(guard Bash 'git checkout -- tracked.txt')" == "allow" ]]
}

@test "reset --hard on a CLEAN tree is allowed" {
    [[ "$(guard Bash 'git reset --hard')" == "allow" ]]
}

@test "restore scoped to a CLEAN path is allowed while another file is dirty" {
    dirty_tracked   # tracked.txt dirty, second.txt clean
    [[ "$(guard Bash 'git restore second.txt')" == "allow" ]]
}

@test "branch switch (git checkout <branch>) is never destructive" {
    dirty_tracked
    [[ "$(guard Bash 'git checkout main')" == "allow" ]]
}

@test "non-destructive git verb (status) is allowed even when dirty" {
    dirty_tracked
    [[ "$(guard Bash 'git status')" == "allow" ]]
}

@test "non-git command is allowed" {
    [[ "$(guard Bash 'rm tracked.txt')" == "allow" ]]
}

# ── prefix / global-option / segmentation parsing ──────────────────────

@test "sudo-prefixed destructive op is still classified (dirty → deny)" {
    dirty_tracked
    [[ "$(guard Bash 'sudo git reset --hard')" == "deny" ]]
}

@test "env-prefixed destructive op is still classified (dirty → deny)" {
    dirty_tracked
    [[ "$(guard Bash 'env GIT_PAGER=cat git reset --hard')" == "deny" ]]
}

@test "-C/-c global options before the subcommand are skipped (dirty → deny)" {
    dirty_tracked
    [[ "$(guard Bash "git -c core.pager=cat -C $REPO reset --hard")" == "deny" ]]
}

@test "destructive op in a compound command (after &&) is caught" {
    dirty_tracked
    [[ "$(guard Bash 'git status && git reset --hard')" == "deny" ]]
}

@test "destructive op after a semicolon is caught" {
    dirty_tracked
    [[ "$(guard Bash 'echo hi ; git checkout .')" == "deny" ]]
}

# ── opt-out / non-Bash / protocol ──────────────────────────────────────

@test "CLAUDE_GIT_GUARD=0 disables the guard (allow, empty)" {
    dirty_tracked
    local json
    json=$(jq -nc --arg w "$REPO" '{tool_name:"Bash", tool_input:{command:"git reset --hard"}, cwd:$w}')
    run bash -c "printf '%s' '$json' | CLAUDE_GIT_GUARD=0 '$DEPLOY/hooks/git-guard.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "non-Bash tool is allowed even with a destructive-looking arg" {
    dirty_tracked
    [[ "$(guard Edit 'git reset --hard')" == "allow" ]]
}

@test "deny payload is a valid PreToolUse decision (claude + codex schema)" {
    dirty_tracked
    local json
    json=$(jq -nc --arg w "$REPO" '{tool_name:"Bash", tool_input:{command:"git reset --hard"}, cwd:$w}')
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/git-guard.sh'"
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" == "PreToolUse" ]]
    [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" == "deny" ]]
    [[ -n "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" ]]
}

# ── fail-open robustness (a broken guard must never block) ─────────────

@test "malformed stdin fails open (allow, exit 0)" {
    run bash -c "printf 'not json' | '$DEPLOY/hooks/git-guard.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "missing logic file fails open (allow, exit 0)" {
    rm "$DEPLOY/lib/git-guard.js"
    dirty_tracked
    local json
    json=$(jq -nc --arg w "$REPO" '{tool_name:"Bash", tool_input:{command:"git reset --hard"}, cwd:$w}')
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/git-guard.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

@test "cwd outside any git repo fails open (allow)" {
    local outside="$TEST_HOME/not-a-repo"
    mkdir -p "$outside"
    local json
    json=$(jq -nc --arg w "$outside" '{tool_name:"Bash", tool_input:{command:"git reset --hard"}, cwd:$w}')
    run bash -c "printf '%s' '$json' | '$DEPLOY/hooks/git-guard.sh'"
    [ "$status" -eq 0 ]
    [[ -z "$output" ]]
}

# ── Cursor adapter (beforeShellExecution, exit 2 = deny) ───────────────
# Cursor's deploy carries only .sh files and blocks on exit code 2, not the
# nested JSON. The adapter resolves the shared lib via $DOTFILES_DIR.

# exit 2 = deny, exit 0 = allow.
cursor_guard() {
    local cmd="$1"
    local json
    json=$(jq -nc --arg c "$cmd" --arg w "$REPO" \
        '{hook_event_name:"beforeShellExecution", command:$c, cwd:$w}')
    DOTFILES_DIR="$REAL_DOTFILES_DIR" run bash -c "printf '%s' '$json' | '$CURSOR_HOOK'"
    echo "$status"
}

@test "cursor reset --hard on a dirty tree is denied (exit 2)" {
    dirty_tracked
    [[ "$(cursor_guard 'git reset --hard')" == "2" ]]
}

@test "cursor reset --hard on a CLEAN tree is allowed (exit 0)" {
    [[ "$(cursor_guard 'git reset --hard')" == "0" ]]
}

@test "cursor non-git command is allowed (exit 0)" {
    [[ "$(cursor_guard 'ls -la')" == "0" ]]
}

@test "cursor CLAUDE_GIT_GUARD=0 disables the hook (exit 0)" {
    dirty_tracked
    local json
    json=$(jq -nc --arg w "$REPO" '{hook_event_name:"beforeShellExecution", command:"git reset --hard", cwd:$w}')
    DOTFILES_DIR="$REAL_DOTFILES_DIR" run bash -c "printf '%s' '$json' | CLAUDE_GIT_GUARD=0 '$CURSOR_HOOK'"
    [ "$status" -eq 0 ]
}

# ── Copilot adapter (preToolUse, JSON-string toolArgs, deny via stdout) ─
# Copilot's toolArgs is a JSON *string* the hook must double-parse; deny is a
# {permissionDecision:"deny",...} object on stdout + exit 0.

# Echo deny|allow from the Copilot adapter's stdout.
copilot_guard() {
    local tool="$1" cmd="$2"
    local toolargs json
    toolargs=$(jq -nc --arg c "$cmd" '{command:$c}')      # the inner object
    json=$(jq -nc --arg t "$tool" --arg a "$toolargs" --arg w "$REPO" \
        '{toolName:$t, toolArgs:$a, cwd:$w}')             # toolArgs is a STRING
    DOTFILES_DIR="$REAL_DOTFILES_DIR" run bash -c "printf '%s' '$json' | '$COPILOT_HOOK'"
    [ "$status" -eq 0 ]
    if [[ -z "$output" ]]; then echo "allow"; else
        jq -r '.permissionDecision' <<<"$output"
    fi
}

@test "copilot bash reset --hard on a dirty tree is denied" {
    dirty_tracked
    [[ "$(copilot_guard bash 'git reset --hard')" == "deny" ]]
}

@test "copilot shell (SDK tool name) reset --hard on a dirty tree is denied" {
    dirty_tracked
    [[ "$(copilot_guard shell 'git reset --hard')" == "deny" ]]
}

@test "copilot reset --hard on a CLEAN tree is allowed (empty stdout)" {
    [[ "$(copilot_guard bash 'git reset --hard')" == "allow" ]]
}

@test "copilot deny payload carries a permissionDecisionReason" {
    dirty_tracked
    local toolargs json
    toolargs=$(jq -nc '{command:"git reset --hard"}')
    json=$(jq -nc --arg a "$toolargs" --arg w "$REPO" '{toolName:"bash", toolArgs:$a, cwd:$w}')
    DOTFILES_DIR="$REAL_DOTFILES_DIR" run bash -c "printf '%s' '$json' | '$COPILOT_HOOK'"
    [ "$status" -eq 0 ]
    [[ "$(jq -r '.permissionDecision' <<<"$output")" == "deny" ]]
    [[ -n "$(jq -r '.permissionDecisionReason' <<<"$output")" ]]
}

@test "copilot non-shell tool is allowed (empty stdout)" {
    dirty_tracked
    [[ "$(copilot_guard write 'git reset --hard')" == "allow" ]]
}

# ── opencode adapter (plugin tool.execute.before, throw = deny) ────────
# opencode has no shell-command hook; its plugin intercepts the bash tool and
# throws on a destructive-dirty op. Exercised by importing the plugin in node
# and driving the returned tool.execute.before handler.

OPENCODE_PLUGIN="$REAL_DOTFILES_DIR/chezmoi/dot_config/opencode/plugins/git-guard.js"

# Echo "deny" if the handler throws, else "allow".
opencode_guard() {
    local tool="$1" cmd="$2" dir="${3:-$REPO}"
    DOTFILES_DIR="$REAL_DOTFILES_DIR" \
    OG_PLUGIN="$OPENCODE_PLUGIN" OG_TOOL="$tool" OG_CMD="$cmd" OG_DIR="$dir" \
    run node --input-type=module -e '
      const { GitGuard } = await import(process.env.OG_PLUGIN);
      const hooks = await GitGuard({ directory: process.env.OG_DIR });
      const before = hooks["tool.execute.before"];
      if (!before) { console.log("allow"); process.exit(0); }
      try {
        await before({ tool: process.env.OG_TOOL }, { args: { command: process.env.OG_CMD } });
        console.log("allow");
      } catch { console.log("deny"); }
    '
    [ "$status" -eq 0 ]
    echo "$output"
}

@test "opencode plugin denies reset --hard on a dirty tree" {
    dirty_tracked
    [[ "$(opencode_guard bash 'git reset --hard')" == "deny" ]]
}

@test "opencode plugin allows reset --hard on a CLEAN tree" {
    [[ "$(opencode_guard bash 'git reset --hard')" == "allow" ]]
}

@test "opencode plugin ignores non-bash tools" {
    dirty_tracked
    [[ "$(opencode_guard read 'git reset --hard')" == "allow" ]]
}

@test "opencode plugin CLAUDE_GIT_GUARD=0 disables (no handler registered)" {
    dirty_tracked
    DOTFILES_DIR="$REAL_DOTFILES_DIR" OG_PLUGIN="$OPENCODE_PLUGIN" OG_DIR="$REPO" \
    run env CLAUDE_GIT_GUARD=0 node --input-type=module -e '
      const { GitGuard } = await import(process.env.OG_PLUGIN);
      const hooks = await GitGuard({ directory: process.env.OG_DIR });
      console.log(hooks["tool.execute.before"] ? "armed" : "disabled");
    '
    [ "$status" -eq 0 ]
    [[ "$output" == "disabled" ]]
}

# ── deploy wiring ──────────────────────────────────────────────────────

@test "registry registers git-guard as a PreToolUse hook matching Bash for claude+codex" {
    local reg="$REAL_DOTFILES_DIR/agents/hooks/registry.yaml"
    [[ "$(yq -r '.hooks.git-guard.event' "$reg")" == "PreToolUse" ]]
    [[ "$(yq -r '.hooks.git-guard.script' "$reg")" == "agents/hooks/git-guard.sh" ]]
    [[ "$(yq -r '.hooks.git-guard.matcher' "$reg")" == "Bash" ]]
    [[ "$(yq -r '.hooks.git-guard.shared_assets[0]' "$reg")" == "agents/lib/git-guard.js" ]]
    [[ "$(yq -r '.hooks.git-guard.harnesses | join(",")' "$reg")" == "claude,codex" ]]
}

@test "cursor hooks.json wires git-guard on beforeShellExecution" {
    local hj="$REAL_DOTFILES_DIR/cursor/plugins/local/cheese-grok/hooks.json"
    run jq -e '.hooks.beforeShellExecution[] | select(.command == "./hooks/git-guard.sh")' "$hj"
    [ "$status" -eq 0 ]
}

@test "copilot config registers a preToolUse command hook with a shell matcher" {
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/private_dot_copilot/hooks/git-guard.json.tmpl"
    # The template references {{ .chezmoi.homeDir }}; render it and assert shape.
    local rendered
    rendered=$(chezmoi --source "$REAL_DOTFILES_DIR/chezmoi" execute-template < "$tmpl")
    [[ "$(jq -r '.hooks.preToolUse[0].type' <<<"$rendered")" == "command" ]]
    [[ "$(jq -r '.hooks.preToolUse[0].matcher' <<<"$rendered")" == "bash|shell" ]]
    [[ "$(jq -r '.hooks.preToolUse[0].bash' <<<"$rendered")" == */.copilot/hooks/git-guard.sh ]]
}

@test "opencode plugin is deployed to the plugins dir and exports a Plugin" {
    local p="$REAL_DOTFILES_DIR/chezmoi/dot_config/opencode/plugins/git-guard.js"
    [[ -f "$p" ]]
    grep -q 'tool.execute.before' "$p"
    grep -q 'export const GitGuard' "$p"
}
