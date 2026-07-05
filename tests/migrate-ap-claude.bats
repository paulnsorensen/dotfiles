#!/usr/bin/env bats
# Behavioural tests for chezmoi/.chezmoiscripts/run_once_before_migrate-ap-claude.sh
# — the one-time migration off the ap live install before the first
# chezmoi-authoritative apply (spec: chezmoi-authoritative-claude).
#
# The script mutates live user state (backups, rm -rf of the ap plugin trees,
# symlink unlinks), so every branch is exercised against a sandbox $HOME.

load test_helper

SCRIPT_REL="chezmoi/.chezmoiscripts/run_once_before_migrate-ap-claude.sh"

setup() {
    setup_test_env
    export SCRIPT="$REAL_DOTFILES_DIR/$SCRIPT_REL"
}

teardown() { teardown_test_env; }

run_migration() { run bash "$SCRIPT"; }

@test "migrate-ap: fresh box (no ~/.claude at all) exits 0 with no side effects" {
    [[ ! -e "$HOME/.claude" ]]
    run_migration
    [ "$status" -eq 0 ]
    [[ ! -e "$HOME/.claude" ]]
}

@test "migrate-ap: backs up settings.json and ~/.claude.json before first authoritative apply" {
    mkdir -p "$HOME/.claude"
    echo '{"model":"opus"}' > "$HOME/.claude/settings.json"
    echo '{"mcpServers":{}}' > "$HOME/.claude.json"
    run_migration
    [ "$status" -eq 0 ]
    # Originals still in place (the apply itself rewrites them, not this script).
    [ -f "$HOME/.claude/settings.json" ]
    [ -f "$HOME/.claude.json" ]
    # Timestamped backups exist and carry the original content.
    local b_settings b_json
    b_settings=$(compgen -G "$HOME/.claude/settings.json.pre-chezmoi-authoritative.*.bak")
    b_json=$(compgen -G "$HOME/.claude.json.pre-chezmoi-authoritative.*.bak")
    [ -n "$b_settings" ] && [ -n "$b_json" ]
    diff "$HOME/.claude/settings.json" "$b_settings"
    diff "$HOME/.claude.json" "$b_json"
}

@test "migrate-ap: removes the ap plugin trees but leaves Claude's own plugin state alone" {
    mkdir -p "$HOME/.claude/plugins/local/global" "$HOME/.claude/plugins/marketplaces/official"
    echo "ap-rendered" > "$HOME/.claude/plugins/local/global/plugin.json"
    echo "claude-owned" > "$HOME/.claude/plugins/marketplaces/official/marketplace.json"
    echo '{"repositories":{}}' > "$HOME/.claude/plugins/config.json"
    run_migration
    [ "$status" -eq 0 ]
    [[ ! -e "$HOME/.claude/plugins/local" ]]
    # Non-goal boundary: Claude's runtime plugin cache/marketplace state untouched.
    [ -f "$HOME/.claude/plugins/marketplaces/official/marketplace.json" ]
    [ -f "$HOME/.claude/plugins/config.json" ]
}

@test "migrate-ap: removes legacy asset-installer manifests, keeps the assets themselves" {
    local d
    for d in commands hooks reference workflows; do
        mkdir -p "$HOME/.claude/$d"
        echo "manifest" > "$HOME/.claude/$d/.dotfiles-managed-claude-assets"
        echo "asset" > "$HOME/.claude/$d/keep.md"
    done
    run_migration
    [ "$status" -eq 0 ]
    for d in commands hooks reference workflows; do
        [[ ! -e "$HOME/.claude/$d/.dotfiles-managed-claude-assets" ]]
        [ -f "$HOME/.claude/$d/keep.md" ]
    done
}

@test "migrate-ap: unlinks write-through symlinks WITHOUT deleting the repo files they point at" {
    # The legacy ~/.claude/{hooks,reference,agents,mcp} symlinks point INTO the
    # dotfiles checkout; the migration must remove only the link so the exact_
    # dir can replace it — following it would let chezmoi delete files inside
    # the repo. agents gains an exact_ dir in this regime; a stale mcp link
    # would otherwise linger dangling.
    local repo_side="$TEST_HOME/fake-checkout"
    mkdir -p "$repo_side/hooks" "$repo_side/reference" "$repo_side/agents" "$repo_side/mcp" "$HOME/.claude"
    echo "repo file" > "$repo_side/hooks/git-guard.sh"
    echo "repo doc" > "$repo_side/reference/doc.md"
    echo "repo agent" > "$repo_side/agents/coder.md"
    echo "repo mcp" > "$repo_side/mcp/registry.yaml"
    local item
    for item in hooks reference agents mcp; do
        ln -s "$repo_side/$item" "$HOME/.claude/$item"
    done
    run_migration
    [ "$status" -eq 0 ]
    for item in hooks reference agents mcp; do
        [[ ! -e "$HOME/.claude/$item" && ! -L "$HOME/.claude/$item" ]]
    done
    # Link targets (the repo checkout) untouched.
    [ -f "$repo_side/hooks/git-guard.sh" ]
    [ -f "$repo_side/reference/doc.md" ]
    [ -f "$repo_side/agents/coder.md" ]
    [ -f "$repo_side/mcp/registry.yaml" ]
}

@test "migrate-ap: leaves REAL hooks/reference directories untouched (half-migrated state)" {
    mkdir -p "$HOME/.claude/hooks"
    echo "user file" > "$HOME/.claude/hooks/sentinel"
    run_migration
    [ "$status" -eq 0 ]
    [[ -d "$HOME/.claude/hooks" && ! -L "$HOME/.claude/hooks" ]]
    [ "$(cat "$HOME/.claude/hooks/sentinel")" = "user file" ]
}
