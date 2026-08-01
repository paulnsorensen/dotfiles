#!/usr/bin/env bats

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
REGISTRY="$DOTFILES_DIR/agents/registry.yaml"
OMP_AGENTS="$DOTFILES_DIR/chezmoi/dot_omp/private_agent/agents"
OMP_CONFIG="$DOTFILES_DIR/chezmoi/.chezmoidata/omp.yaml"

canonical_agents() {
    yq -oy -r '.agents | keys | .[]' "$REGISTRY"
}

omp_agent_names() {
    local file
    for file in "$OMP_AGENTS"/*.md; do
        basename "${file%.md}"
    done | sort
}

frontmatter() {
    yq --front-matter=extract -oy -r "$1" "$2"
}

expected_omp_model() {
    case "$1" in
        gpt-5.6-sol)   printf '%s\n' '@strong' ;;
        gpt-5.6-terra) printf '%s\n' '@balanced' ;;
        gpt-5.6-luna|gpt-5.4-mini) printf '%s\n' '@fast' ;;
        *) return 1 ;;
    esac
}

expected_omp_thinking() {
    case "$1" in
        reviewer) echo xhigh ;;
        ghostbuster|researcher) echo high ;;
        generalist) echo xhigh ;;
        roquefort-wrecker|coder) echo xhigh ;;
        explorer) echo high ;;
        nih-scanner) echo medium ;;
        duckdb-expert|whey-drainer|worktree-content-digest) echo low ;;
        *) return 1 ;;
    esac
}

@test "OMP defines exactly every canonical agent plus its native reviewer" {
    local expected actual
    expected="$(
        {
            canonical_agents
            printf '%s\n' cheese-reviewer
        } | sort
    )"
    actual="$(omp_agent_names)"

    [[ "$actual" == "$expected" ]]
}

@test "OMP canonical agents use valid native frontmatter and workload routes" {
    local name file codex_model expected_model actual_model expected_thinking actual_thinking description tools tool

    while IFS= read -r name; do
        file="$OMP_AGENTS/$name.md"
        [[ "$(frontmatter '.name' "$file")" == "$name" ]]

        description="$(frontmatter '.description' "$file")"
        [[ -n "$description" && "$description" != "null" ]]

        codex_model="$(yq -oy -r ".agents.\"$name\".models.codex" "$REGISTRY")"
        expected_model="$(expected_omp_model "$codex_model")"
        actual_model="$(frontmatter '.model' "$file")"
        [[ "$actual_model" == "$expected_model" ]]

        expected_thinking="$(expected_omp_thinking "$name")"
        actual_thinking="$(frontmatter '.thinkingLevel' "$file")"
        [[ "$actual_thinking" == "$expected_thinking" ]]

        tools="$(frontmatter '.tools' "$file")"
        [[ -n "$tools" && "$tools" != "null" ]]
        IFS=',' read -r -a tool_list <<< "$tools"
        for tool in "${tool_list[@]}"; do
            case "$tool" in
                read|grep|glob|bash|edit|write|ast_grep|ast_edit|lsp|web_search) ;;
                *) echo "$name exposes unsupported OMP tool: $tool" >&2; return 1 ;;
            esac
        done
    done < <(canonical_agents)
}

@test "OMP canonical agents preserve registry mutation and network boundaries" {
    local name file denied tools

    while IFS= read -r name; do
        file="$OMP_AGENTS/$name.md"
        tools=",$(frontmatter '.tools' "$file"),"
        denied="$(yq -oy -r ".agents.\"$name\".disallowedTools[]?" "$REGISTRY")"

        if grep -qx 'Edit' <<< "$denied"; then
            [[ "$tools" != *,edit,* && "$tools" != *,ast_edit,* ]]
        fi
        if grep -qx 'Write' <<< "$denied"; then
            [[ "$tools" != *,write,* ]]
        fi
        if grep -Eq '^(WebSearch|WebFetch)$' <<< "$denied"; then
            [[ "$tools" != *,web_search,* ]]
        fi
    done < <(canonical_agents)
}

@test "OMP canonical prompts contain no foreign harness tool names" {
    local name file

    while IFS= read -r name; do
        file="$OMP_AGENTS/$name.md"
        if grep -Eq 'tilth_|mcp__tilth|ToolSearch|AskUserQuestion|NotebookEdit|MultiEdit|TodoWrite|WebFetch' "$file"; then
            echo "$name still references a foreign harness tool" >&2
            return 1
        fi
    done < <(canonical_agents)
}

@test "OMP custom model tiers resolve to the intended OpenAI families" {
    [[ "$(yq -oy -r '.omp.config.modelRoles.strong' "$OMP_CONFIG")" == "openai-codex/gpt-5.6-sol" ]]
    [[ "$(yq -oy -r '.omp.config.modelRoles.balanced' "$OMP_CONFIG")" == "openai-codex/gpt-5.6-terra" ]]
    [[ "$(yq -oy -r '.omp.config.modelRoles.fast' "$OMP_CONFIG")" == "openai-codex/gpt-5.6-luna" ]]
    [[ "$(yq -oy -r '.omp.config.modelRoles.default' "$OMP_CONFIG")" == "@balanced:medium" ]]
    [[ "$(yq -oy -r '.omp.config.modelRoles.plan' "$OMP_CONFIG")" == "@strong:xhigh" ]]
    [[ "$(yq -oy -r '.omp.config.modelRoles.task' "$OMP_CONFIG")" == "@fast" ]]
    [[ "$(frontmatter '.model' "$OMP_AGENTS/cheese-reviewer.md")" == "@strong" ]]
    [[ "$(frontmatter '.thinkingLevel' "$OMP_AGENTS/cheese-reviewer.md")" == "xhigh" ]]
}
