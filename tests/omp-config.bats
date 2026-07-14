#!/usr/bin/env bats
# Behavioural tests for chezmoi/dot_omp/private_agent/modify_config.yml — the
# modify_ script that makes ~/.omp/agent/config.yml repo-authoritative on every
# apply, mirroring the claude wholesale-authoring recipe.
#
# The script reads the live file on stdin and emits the desired document
# composed from the `omp.config` subtree of
# $CHEZMOI_SOURCE_DIR/.chezmoidata/omp.yaml. Live drift on managed keys is
# WIPED; setupVersion (machine state) is preserved; unknown live keys halt.
# These tests drive it directly (no real chezmoi) by setting
# CHEZMOI_SOURCE_DIR to the repo's chezmoi dir.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export SCRIPT="$REAL_DOTFILES_DIR/chezmoi/dot_omp/private_agent/modify_config.yml"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    OUT="$TEST_HOME/out.yml"
    export OUT
}

teardown() { teardown_test_env; }

# Run modify_config.yml with $1 as stdin; stdout → $OUT, stderr → $output.
run_modify() {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' <<'STDIN' >'$OUT'
$1
STDIN"
}

@test "omp-config: empty stdin emits the desired document (fresh machine)" {
    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    [ "$(yq '.symbolPreset' "$OUT")" = "nerd" ]
    [ "$(yq '.colorBlindMode' "$OUT")" = "true" ]
    [ "$(yq '.theme.dark' "$OUT")" = "chocolate-donut" ]
    [ "$(yq '.theme.light' "$OUT")" = "light" ]
    [ "$(yq '.defaultThinkingLevel' "$OUT")" = "auto" ]
    [ "$(yq '.modelRoles.vision' "$OUT")" = "openai-codex/gpt-5.6-terra" ]
    [ "$(yq '.modelRoles.default' "$OUT")" = "openai-codex/gpt-5.6-terra:medium" ]
    [ "$(yq '.modelRoles.plan' "$OUT")" = "openai-codex/gpt-5.6-sol:xhigh" ]
    [ "$(yq '.modelRoles.advisor' "$OUT")" = "openai-codex/gpt-5.6-sol" ]
    [ "$(yq '.modelRoles.tiny' "$OUT")" = "openai-codex/gpt-5.6-luna" ]
    [ "$(yq '.modelRoles.slow' "$OUT")" = "openai-codex/gpt-5.6-sol:xhigh" ]
    [ "$(yq '.textVerbosity' "$OUT")" = "medium" ]
    [ "$(yq '.tools.artifactSpillThreshold' "$OUT")" = "2" ]
    [ "$(yq '.tools.artifactHeadBytes' "$OUT")" = "1" ]
    [ "$(yq '.tools.artifactTailBytes' "$OUT")" = "1" ]
    [ "$(yq '.read.toolResultPreview' "$OUT")" = "false" ]
    [ "$(yq '.skills.enableSkillCommands' "$OUT")" = "true" ]
    [ "$(yq '.tui.tight' "$OUT")" = "true" ]
    [ "$(yq '.startup.quiet' "$OUT")" = "true" ]
    [ "$(yq '.compaction.thresholdTokens' "$OUT")" = "120000" ]
    [ "$(yq '.compaction.strategy' "$OUT")" = "snapcompact" ]
    [ "$(yq '.compaction.keepRecentTokens' "$OUT")" = "20000" ]
    [ "$(yq '.compaction.midTurnEnabled' "$OUT")" = "true" ]
    [ "$(yq '.compaction.autoContinue' "$OUT")" = "true" ]
    [ "$(yq '.lsp.enabled' "$OUT")" = "true" ]
    [ "$(yq '.lsp.lazy' "$OUT")" = "true" ]
    [ "$(yq '.lsp.diagnosticsOnWrite' "$OUT")" = "true" ]
    [ "$(yq '.lsp.diagnosticsOnEdit' "$OUT")" = "false" ]
    [ "$(yq '.lsp.formatOnWrite' "$OUT")" = "false" ]
    [ "$(yq '.modelRoles.smol' "$OUT")" = "openai-codex/gpt-5.6-luna" ]
    [ "$(yq '.modelRoles.task' "$OUT")" = "openai-codex/gpt-5.6-luna" ]
    [ "$(yq '.modelRoles.commit' "$OUT")" = "openai-codex/gpt-5.6-luna" ]
    [ "$(yq '.disabledProviders | join(",")' "$OUT")" = "claude,codex,cursor,gemini,github,opencode,agents-md" ]
    # setupVersion is machine state — never authored on a fresh machine.
    [ "$(yq 'has("setupVersion")' "$OUT")" = "false" ]
}

@test "omp-config: managed-key drift is wiped, setupVersion preserved" {
    # In-app symbolPreset/theme change + a hand-edited (emptied) disabledProviders
    # list must be driven back to the native-only registry values; setupVersion survives.
    run_modify 'symbolPreset: ascii
theme:
  dark: titanium
  light: dark
disabledProviders: []
setupVersion: 1'
    [ "$status" -eq 0 ]
    [ "$(yq '.symbolPreset' "$OUT")" = "nerd" ]
    [ "$(yq '.theme.dark' "$OUT")" = "chocolate-donut" ]
    [ "$(yq '.theme.light' "$OUT")" = "light" ]
    [ "$(yq '.disabledProviders | join(",")' "$OUT")" = "claude,codex,cursor,gemini,github,opencode,agents-md" ]
    [ "$(yq '.setupVersion' "$OUT")" = "1" ]
}

@test "omp-config: unknown key halts (non-zero, no write, key + registry named on stderr)" {
    run_modify 'symbolPreset: nerd
unexpectedThemeKnob: dark'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]                                   # live left unmodified (nothing written)
    [[ "$output" == *"unexpectedThemeKnob"* ]]        # offending key surfaced
    [[ "$output" == *".chezmoidata/omp.yaml"* ]]      # registry path named
}

@test "omp-config: corrupt (non-map) live file halts with guidance" {
    run_modify '[1, 2, 3]'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]
    [[ "$output" == *"not a YAML map"* ]]
}

@test "omp-config: unparseable live file halts with guidance" {
    run_modify 'foo: [bar'
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]
    [[ "$output" == *"not a YAML map"* ]]
}

@test "omp-config: missing yq passes the live file through unchanged" {
    # Restrict PATH to a bin dir without yq/jq; symlink only the externals the
    # passthrough branch needs (bash, cat). printf/[ are bash builtins.
    local fakebin="$TEST_HOME/noyq-bin"
    mkdir -p "$fakebin"
    ln -s "$(command -v bash)" "$fakebin/bash"
    ln -s "$(command -v cat)"  "$fakebin/cat"
    local live='symbolPreset: ascii'
    run bash -c "PATH='$fakebin' CHEZMOI_SOURCE_DIR='$CZ_SRC' '$fakebin/bash' '$SCRIPT' <<'STDIN' >'$OUT'
$live
STDIN"
    [ "$status" -eq 0 ]
    # Unchanged: still the live ascii value, no enforcement applied.
    [ "$(cat "$OUT")" = "symbolPreset: ascii" ]
    # Skipped enforcement is signalled on stderr, not silent.
    [[ "$output" == *"yq missing"* ]]
}

@test "omp-config: missing registry file halts non-zero" {
    local tmpsrc="$TEST_HOME/no-reg"
    mkdir -p "$tmpsrc/.chezmoidata"   # exists, but omp.yaml absent
    run bash -c "CHEZMOI_SOURCE_DIR='$tmpsrc' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"registry missing"* ]]
}

@test "omp-config: registry lacking .omp.config halts (schema error names registry)" {
    # Registry file present but the omp.config subtree is absent → yq yields
    # `null`. Without validation the script would write the literal `null`
    # document (fresh machine) or misattribute the null merge to the user's
    # keys (existing machine). It must halt with a registry/schema error.
    local tmpsrc="$TEST_HOME/no-config"
    mkdir -p "$tmpsrc/.chezmoidata"
    printf 'omp:\n  other: value\n' >"$tmpsrc/.chezmoidata/omp.yaml"
    run bash -c "CHEZMOI_SOURCE_DIR='$tmpsrc' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -ne 0 ]
    [ ! -s "$OUT" ]                                   # nothing written
    [[ "$output" == *".omp.config"* ]]                # the missing key named
    [[ "$output" == *".chezmoidata/omp.yaml"* ]]      # registry path named
}

@test "omp-mcp: native user config keeps only direct MCP servers" {
    local cfg="$REAL_DOTFILES_DIR/chezmoi/dot_omp/private_agent/mcp.json"
    local plugin_registry="$REAL_DOTFILES_DIR/agents/plugins/registry.yaml"
    jq -e '.mcpServers.context7.command == "npx"' "$cfg"
    jq -e '.mcpServers.context7.args == ["-y", "@upstash/context7-mcp"]' "$cfg"
    jq -e '.mcpServers.context7.env.CONTEXT7_API_KEY == "${CONTEXT7_API_KEY}"' "$cfg"
    jq -e '.mcpServers | has("hallouminate") | not' "$cfg"
    jq -e '.mcpServers | has("milknado") | not' "$cfg"

    # Plugin-owned MCPs arrive through OMP's native plugin discovery as
    # plugin:server namespaces. Listing the same server here creates duplicate
    # bare + plugin-prefixed MCP instances.
    local duplicates
    duplicates=$(
        comm -12 \
            <(jq -r '.mcpServers | keys[]' "$cfg" | sort) \
            <(yq -r '.plugins | keys | .[]' "$plugin_registry" | sort)
    )
    if [ -n "$duplicates" ]; then
        echo "dot_omp/private_agent/mcp.json duplicates plugin-owned MCP server(s):"
        printf '%s\n' "$duplicates"
        return 1
    fi
}
# --- models.yml template↔registry seam -------------------------------------
# dot_omp/private_agent/models.yml.tmpl authors ~/.omp/agent/models.yml WHOLESALE
# from the `omp.models` subtree via `{{ .omp.models | toYaml }}`. These lock the
# render: it must parse as YAML and pin the local-llm provider's contextWindow
# per model to the llama-swap --ctx-size values (inflating them overflows the
# real llama.cpp n_ctx and breaks requests).

@test "omp-models: template renders parseable YAML with the pinned local-llm provider" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local tmpl="$REAL_DOTFILES_DIR/chezmoi/dot_omp/private_agent/models.yml.tmpl"
    run chezmoi execute-template --source "$REAL_DOTFILES_DIR/chezmoi" < "$tmpl"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$OUT"
    # No unexpanded template syntax leaked into the rendered file.
    ! grep -qF '{{' "$OUT"
    # Parses as a YAML map with exactly the local-llm provider.
    [ "$(yq '.providers | keys | .[]' "$OUT")" = "local-llm" ]
    [ "$(yq '.providers.local-llm.baseUrl' "$OUT")" = "http://127.0.0.1:4000/v1" ]
    [ "$(yq '.providers.local-llm.api' "$OUT")" = "openai-completions" ]
    [ "$(yq '.providers.local-llm.auth' "$OUT")" = "none" ]
    # Exactly 4 models — omp shows this as the `local-llm (4)` group.
    [ "$(yq '.providers.local-llm.models | length' "$OUT")" = "4" ]
    # contextWindow pinned per model id to the llama-swap --ctx-size (id-keyed,
    # so a reordering of the models array cannot mask a wrong value).
    [ "$(yq '.providers.local-llm.models[] | select(.id == "local-haiku").contextWindow' "$OUT")" = "16384" ]
    [ "$(yq '.providers.local-llm.models[] | select(.id == "local-sonnet").contextWindow' "$OUT")" = "32768" ]
    [ "$(yq '.providers.local-llm.models[] | select(.id == "local-coder").contextWindow' "$OUT")" = "32768" ]
    [ "$(yq '.providers.local-llm.models[] | select(.id == "local-vision").contextWindow' "$OUT")" = "8192" ]
    # local-vision is the only image-capable model (input carries `image`).
    [ "$(yq '.providers.local-llm.models[] | select(.id == "local-vision").input | contains(["image"])' "$OUT")" = "true" ]
}

# --- models.yml localLLM opt-in gate ---------------------------------------
# models.yml advertises a LiteLLM provider that only exists on machines that
# opted into the local-llm stack. It MUST ride the same `.chezmoiignore`
# localLLM gate as the rest of the stack, or a non-LLM box gets a models.yml
# pointing at a proxy that isn't installed. Render .chezmoiignore as a template
# (the gate uses `get . "localLLM"`) and assert the target path is ignored when
# the flag is off and applied when it is on.

@test "omp-models: .omp/agent/models.yml is ignored when localLLM is off" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/cz-off.toml"
    cat > "$cfg" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
TOML
    run chezmoi --config "$cfg" --source "$REAL_DOTFILES_DIR/chezmoi" \
        execute-template < "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    [ "$status" -eq 0 ]
    # localLLM absent (→ falsy): the models.yml target is ignored, never applied.
    [[ "$output" == *".omp/agent/models.yml"* ]]
}

@test "omp-models: .omp/agent/models.yml is applied when localLLM is on" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/cz-on.toml"
    cat > "$cfg" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
localLLM = true
TOML
    run chezmoi --config "$cfg" --source "$REAL_DOTFILES_DIR/chezmoi" \
        execute-template < "$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    [ "$status" -eq 0 ]
    # localLLM on: the not-localLLM ignore block collapses, so the models.yml
    # target is NOT in the ignore list (chezmoi applies it).
    [[ "$output" != *".omp/agent/models.yml"* ]]
}

# --- .chezmoiignore negation ordering -------------------------------------
# .chezmoiignore is last-match-wins: the !.omp/agent/APPEND_SYSTEM.md re-include
# only survives the global *.md ignore because it is positioned AFTER it. A
# reorder that moves the negation above *.md would silently stop deploying the
# managed prompt addendum. Pin the ordering.
@test "omp-ignore: APPEND_SYSTEM.md re-include stays after the *.md ignore" {
    local ignore="$REAL_DOTFILES_DIR/chezmoi/.chezmoiignore"
    local md_line neg_line
    md_line=$(grep -n '^\*\.md$' "$ignore" | head -1 | cut -d: -f1)
    neg_line=$(grep -n '^!\.omp/agent/APPEND_SYSTEM\.md$' "$ignore" | head -1 | cut -d: -f1)
    [ -n "$md_line" ]
    [ -n "$neg_line" ]
    # Negation must come strictly after the glob ignore (last match wins).
    [ "$neg_line" -gt "$md_line" ]
}

# --- omp extension modules are chezmoi-managed -----------------------------
# rtk.ts and cheese-flair.ts under dot_omp/private_agent/extensions/ deploy to
# ~/.omp/agent/extensions/ (auto-discovered by omp's extension loader). Nothing
# in .chezmoiignore may exclude them, or the extensions silently never deploy.
@test "omp-ext: rtk.ts and cheese-flair.ts are chezmoi-managed" {
    command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed"
    local cfg="$TEST_HOME/cz-ext.toml"
    cat > "$cfg" <<TOML
sourceDir = "$REAL_DOTFILES_DIR/chezmoi"

[data]
email = "test@example.com"
TOML
    run chezmoi --config "$cfg" --source "$REAL_DOTFILES_DIR/chezmoi" managed
    [ "$status" -eq 0 ]
    [[ "$output" == *".omp/agent/extensions/rtk.ts"* ]]
    [[ "$output" == *".omp/agent/extensions/cheese-flair.ts"* ]]
    [[ "$output" == *".omp/agent/APPEND_SYSTEM.md"* ]]
}
