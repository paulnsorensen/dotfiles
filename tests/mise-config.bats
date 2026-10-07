#!/usr/bin/env bats
# Validate the mise manifest — every tool pinned to an exact version, no
# floating specifiers, structurally valid TOML, and the full tool count.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
CONFIG="$DOTFILES_DIR/chezmoi/dot_config/mise/config.toml"

@test "mise config exists" {
    [[ -f "$CONFIG" ]]
}

@test "mise config is valid TOML" {
    run yq '.' "$CONFIG" -p toml -o json
    [[ $status -eq 0 ]]
}

@test "mise config pins exactly 51 tools (42 aqua + 3 core-plugin + 6 backend)" {
    run yq -p=toml -o=json '.tools | length' "$CONFIG"
    [[ $status -eq 0 ]]
    [[ "$output" == "51" ]]
}

@test "no tool version is 'latest' or a floating range specifier" {
    local versions v
    # -r strips yq's JSON string quoting; without it a bare `[[ ]]` comparison
    # never matches. A `case` (not a bare `[[ ]]` per line) is used deliberately:
    # macOS ships bash 3.2, whose `set -e` does not abort a loop body when a
    # non-terminal `[[ ]]` inside it fails — an explicit `return 1` is required.
    versions=$(yq -p=toml -o=json '.tools' "$CONFIG" | jq -r '.[]')
    [[ -n "$versions" ]]
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        case "$v" in
            latest|'^'*|'~'*|*'*'*)
                echo "floating version specifier: $v" >&2
                return 1
                ;;
        esac
    done <<<"$versions"
}

@test "no duplicate keys in the [tools] table" {
    # TOML parsers may silently let a duplicate key's second value win
    # (yq does), which would hide a dropped pin behind an unchanged
    # top-level count. Check the raw source, not the parsed result.
    local keys dupes
    keys=$(awk '/^\[tools\]/{f=1; next} /^\[/{f=0} f && NF && $0 !~ /^#/ {sub(/=.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print}' "$CONFIG")
    [[ -n "$keys" ]]
    dupes=$(echo "$keys" | sort | uniq -d)
    [[ -z "$dupes" ]]
}

@test "claude and codex are pinned to exact tags, not floating" {
    local tool version
    for tool in \
        'aqua:anthropics/claude-code' \
        'aqua:openai/codex'; do
        version="$(yq -p=toml -o=json '.tools' "$CONFIG" | jq -r --arg tool "$tool" '.[$tool]')"
        [[ "$version" =~ ^(v|rust-v)[0-9]+\.[0-9]+\.[0-9]+$ ]]
    done
}

# Pin values move on every `dots sync` bump (bump_mise_manifest) and every
# Renovate PR, so these tests assert the version-string SHAPE of each
# backend, never a literal pin.
tool_version() {
    yq -p=toml -o=json '.tools' "$CONFIG" |
        jq -r --arg tool "$1" '.[$tool] | if type == "object" then .version else . end'
}

@test "eza vendors libgit2 (a host libgit2 link has no RUNPATH on Linux)" {
    run bash -c "yq -p=toml -o=json '.tools' '$CONFIG' | jq -r '.[\"cargo:eza\"].features'"
    [[ "$output" == *vendored-libgit2* ]]
}

@test "non-semver tag shapes are kept raw (rust-analyzer date-stamp, tmux v3.7x)" {
    [[ "$(tool_version 'aqua:rust-lang/rust-analyzer')" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
    [[ "$(tool_version 'aqua:tmux/tmux-builds')" =~ ^v3\.[0-9]+[a-z]?$ ]]
}

@test "core-plugin tools (node, bun, rust) are stripped of git-tag prefixes" {
    local tool
    for tool in node bun rust; do
        [[ "$(tool_version "$tool")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    done
}

@test "backend-managed tools use their backend prefix syntax" {
    local tool
    for tool in \
        'npm:bash-language-server' \
        'npm:yaml-language-server' \
        'npm:basedpyright' \
        'npm:t3' \
        'cargo:eza' \
        'cargo:tokei'; do
        [[ "$(tool_version "$tool")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    done
}

@test "gopls stays dropped (needs a Go toolchain; aqua entry is go_install-type)" {
    run grep -c 'gopls' <(yq -p=toml -o=json '.tools | keys' "$CONFIG")
    [[ "$output" == "0" ]]
}

@test "just check pins XDG_CACHE_HOME before parallel (mise cache leak guard)" {
    # GNU parallel exports XDG_CACHE_HOME to its jobs even when the parent
    # leaves it unset, and mise resolves an empty value to a *relative* `mise`
    # cache dir — every `just check` then dropped mise/aqua-*/bin_paths caches
    # into the repo root. The bats sandbox alone can't cover this: the leak
    # comes from the gate's own fan-out, outside any test's environment.
    # `just check` dispatches its legs through tests/check-affected.sh.
    grep -qF 'tests/check-affected.sh' <(awk '/^check \*ARGS:/{f=1} f' "$DOTFILES_DIR/justfile")
    # shellcheck disable=SC2016  # a literal grep pattern, not an expansion
    grep -qF 'XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}" parallel' "$DOTFILES_DIR/tests/check-affected.sh"
}
