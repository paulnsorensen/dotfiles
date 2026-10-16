#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export SCRIPT="$CZ_SRC/dot_config/opencode/modify_opencode.json"
}

@test "all shared agents render their bodies, models, and step limits" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    local name body model turns
    [ "$(jq '.agent | length' <<<"$output")" -eq 20 ]
    while IFS=$'\t' read -r name body model turns; do
        [ "$(jq -r --arg n "$name" '.agent[$n].model' <<<"$output")" = "openai/$model" ]
        [ "$(jq -r --arg n "$name" '.agent[$n].steps' <<<"$output")" = "$turns" ]
        [ "$(jq -r --arg n "$name" '.agent[$n].prompt' <<<"$output")" = "$(<"$REAL_DOTFILES_DIR/$body")" ]
        [ "$(jq -r --arg n "$name" '.agent[$n].permission.task' <<<"$output")" = "deny" ]
    done < <(yq -o=json '.agents' "$REAL_DOTFILES_DIR/agents/registry.yaml" | jq -r 'to_entries[] | [.key,.value.body_path,.value.models.opencode,.value.maxTurns] | @tsv')
}

@test "role tiers and model catalog use the approved OpenAI IDs" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    jq -e '
        .model == "openai/gpt-6.1-sol" and
        ([.agent.ghostbuster,.agent.explorer,.agent.researcher,.agent["taste-tester"],.agent.coder,.agent.generalist] | all(.model == "openai/gpt-6.1-sol")) and
        (.provider.openai.models | keys == ["gpt-6-astra", "gpt-6-luna", "gpt-6.1-sol"]) and
        ([.agent["nih-scanner"],.agent["roquefort-wrecker"],.agent["duckdb-expert"],.agent["whey-drainer"],.agent["worktree-content-digest"],.agent.runner,.agent.formatter] | all(.model == "openai/gpt-6-luna")) and
        ([.agent.reviewer,.agent.judge,.agent.advisor] | all(.model == "openai/gpt-6-astra")) and
        ([.provider.openai.models[] | .limit] | all(.context == 1050000 and .output == 128000))
    ' <<<"$output"
}

@test "advisor allows only exact read-only Tilth IDs after wildcard deny" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    jq -e '
        .agent.advisor.permission | keys_unsorted as $keys |
        $keys[0] == "*" and
        ([.[] | select(. == "allow")] | length) == 2 and
        .tilth_tilth_read == "allow" and .tilth_tilth_search == "allow" and
        .tilth_tilth_write == "deny" and .hallouminate_add_markdown == null and
        .context7_resolve_library_id == null
    ' <<<"$output"
}

@test "advisor uses its exact model and bounded permissions without a checker" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    jq -e '.agent.advisor.model == "openai/gpt-6-astra" and .agent.advisor.mode == "subagent" and .agent.advisor.steps == 4 and .agent.advisor.permission["*"] == "deny" and .agent.advisor.permission.tilth_tilth_read == "allow" and .agent.advisor.permission.tilth_tilth_search == "allow" and .agent.advisor.permission.tilth_tilth_write == "deny" and .agent.advisor.permission.bash == "deny" and .agent.advisor.permission.task == "deny"' <<<"$output"
    jq -e '.agent["wheypoint-check"] == null' <<<"$output"
    jq -e '.agent.coder.permission.tilth_tilth_write != "deny" and .agent["roquefort-wrecker"].permission.tilth_tilth_write != "deny" and .agent.reviewer.permission.tilth_tilth_write != "deny" and .agent.ghostbuster.permission.tilth_tilth_write == "deny"' <<<"$output"
}

@test "agent drift resets while unknown runtime keys survive" {
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" <<'JSON'
{"agent":{"advisor":{"model":"wrong","permission":{"task":"allow"}},"unknown":{"model":"kept"}},"runtime_key":"kept"}
JSON
    [ "$status" -eq 0 ]
    [ "$(jq -r '.agent.advisor.model' <<<"$output")" = "openai/gpt-6-astra" ]
    [ "$(jq -r '.agent.advisor.permission.task' <<<"$output")" = "deny" ]
    [ "$(jq -r '.agent.unknown.model' <<<"$output")" = "kept" ]
    [[ "$stderr" == *"WARNING"*"unknown"* ]]
    [ "$(jq -r '.runtime_key' <<<"$output")" = "kept" ]
}

@test "agent rendering rejects a missing model and unsafe body path" {
    local registry="$REAL_DOTFILES_DIR/agents/registry.yaml"
    yq -o=json '.' "$registry" | jq '.agents.coder.models.opencode = ""' > "$TEST_HOME/missing-model.json"
    run bash -c 'source "$1"; _cz_opencode_agents_json "$2" "$3"' bash \
        "$REAL_DOTFILES_DIR/.sync-lib.sh" "$TEST_HOME/missing-model.json" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"models.opencode missing or invalid"* ]]

    yq -o=json '.' "$registry" | jq '.agents.coder.body_path = "../secret"' > "$TEST_HOME/unsafe-body.json"
    run bash -c 'source "$1"; _cz_opencode_agents_json "$2" "$3"' bash \
        "$REAL_DOTFILES_DIR/.sync-lib.sh" "$TEST_HOME/unsafe-body.json" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid or missing body_path"* ]]
}

@test "allowlisted specialists deny unrelated MCP tools and retain global bash guards" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    local bash_rules
    bash_rules=$(yq -o=json '.opencode.config.permission.bash' "$CZ_SRC/.chezmoidata/opencode.yaml" | jq -c .)
    jq -e --argjson bash_rules "$bash_rules" '
        [.agent.judge,.agent["duckdb-expert"],.agent.coder,.agent["roquefort-wrecker"]] |
        all(.permission["*"] == "deny" and .permission.bash == $bash_rules and
            .permission.hallouminate_add_markdown == null and .permission.task == "deny")
    ' <<<"$output"
    jq -e '.agent.judge.permission.tilth_tilth_read == "allow" and .agent.judge.permission.tilth_tilth_search == "allow" and .agent.judge.permission.tilth_tilth_write == null and .agent["duckdb-expert"].permission.tilth_tilth_read == "allow" and .agent["duckdb-expert"].permission.tilth_tilth_write == null and .agent.coder.permission.tilth_tilth_write == "allow"' <<<"$output"
    jq -e '.agent.ghostbuster.permission.skill == "deny" and .agent.ghostbuster.permission.websearch == "deny" and .agent.ghostbuster.permission.tilth_tilth_write == "deny" and .agent.researcher.permission.skill == "deny"' <<<"$output"
}

@test "background specialists cannot ask the operator" {
    run env CHEZMOI_SOURCE_DIR="$CZ_SRC" sh "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    jq -e '.agent.ghostbuster.permission.question == "deny" and .agent["nih-scanner"].permission.question == "deny"' <<<"$output"
}

@test "shared wildcard MCP denies use OpenCode tool IDs" {
    yq -o=json '.' "$REAL_DOTFILES_DIR/agents/registry.yaml" |
        jq '.agents.ghostbuster.disallowedTools += ["mcp__hallouminate__*"]' > "$TEST_HOME/wildcard.json"
    run bash -c 'source "$1"; _cz_opencode_agents_json "$2" "$3"' bash \
        "$REAL_DOTFILES_DIR/.sync-lib.sh" "$TEST_HOME/wildcard.json" "$REAL_DOTFILES_DIR"
    [ "$status" -eq 0 ]
    jq -e '.ghostbuster.permission["hallouminate_*"] == "deny"' <<<"$output"
}

@test "modifier reports invalid role data on stderr" {
    local root="$TEST_HOME/source"
    mkdir -p "$root/chezmoi/.chezmoidata" "$root/agents"
    cp "$CZ_SRC/.chezmoidata/opencode.yaml" "$root/chezmoi/.chezmoidata/opencode.yaml"
    ln -s "$CZ_SRC/lib" "$root/chezmoi/lib"
    ln -s "$REAL_DOTFILES_DIR/.sync-lib.sh" "$root/.sync-lib.sh"
    ln -s "$REAL_DOTFILES_DIR/agents/agent_definitions" "$root/agents/agent_definitions"
    yq -o=json '.' "$REAL_DOTFILES_DIR/agents/registry.yaml" | jq '.agents.coder.models.opencode = ""' > "$root/agents/registry.yaml"
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$root/chezmoi" sh "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"opencode agent 'coder': models.opencode missing or invalid"* ]]

    yq -o=json '.' "$REAL_DOTFILES_DIR/agents/registry.yaml" | jq '.agents.coder.body_path = "../secret"' > "$root/agents/registry.yaml"
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$root/chezmoi" sh "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"opencode agent 'coder': invalid or missing body_path"* ]]

    yq -o=json '.' "$REAL_DOTFILES_DIR/agents/registry.yaml" | jq '.agents["Bad Role"] = .agents.coder | del(.agents.coder)' > "$root/agents/registry.yaml"
    run --separate-stderr env CHEZMOI_SOURCE_DIR="$root/chezmoi" sh "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"opencode agent 'Bad Role': invalid or missing body_path"* ]]
}
