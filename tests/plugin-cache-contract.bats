#!/usr/bin/env bats
# Behavioural coverage for the dotfiles-owned native-plugin cache contract.
# Git-backed marketplaces are regenerated under ~/.cache/cheese-flow/plugins;
# the retired ~/.cache/ap/plugins tree is neither read nor removed.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"

    export SCRIPT="$REAL_DOTFILES_DIR/chezmoi/dot_claude/modify_settings.json"
    export BEFORE_TEMPLATE="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_before_sync-claude-plugin-cache.sh.tmpl"
    export AFTER_TEMPLATE="$REAL_DOTFILES_DIR/chezmoi/.chezmoiscripts/run_after_sync-claude-plugins.sh.tmpl"
    export CACHE_LIB="$REAL_DOTFILES_DIR/chezmoi/lib/claude-plugin-reconcile.sh"
    export CZ_SRC="$REAL_DOTFILES_DIR/chezmoi"
    export OUT="$TEST_HOME/settings.json"
}

teardown() { teardown_test_env; }

mk_marketplace() {
    local key="$1"
    local name="$2"
    mkdir -p "$TEST_HOME/.cache/cheese-flow/plugins/$key/.claude-plugin"
    printf '{"name":"%s"}\n' "$name" \
        > "$TEST_HOME/.cache/cheese-flow/plugins/$key/.claude-plugin/marketplace.json"
}

@test "native plugin consumers use the regenerated cheese-flow cache only" {
    mk_marketplace milknado milknado
    mk_marketplace hallouminate hallouminate

    # A legacy tree with a sentinel must remain untouched and cannot satisfy
    # the native overlay when the regenerated tree is present.
    mkdir -p "$TEST_HOME/.cache/ap/plugins/milknado"
    printf 'legacy cache sentinel\n' > "$TEST_HOME/.cache/ap/plugins/milknado/sentinel"

    run bash -c "CHEZMOI_SOURCE_DIR='$CZ_SRC' sh '$SCRIPT' </dev/null >'$OUT'"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.extraKnownMarketplaces.milknado.source.path' "$OUT")" = \
        "$TEST_HOME/.cache/cheese-flow/plugins/milknado" ]
    [ "$(jq -r '.extraKnownMarketplaces.hallouminate.source.path' "$OUT")" = \
        "$TEST_HOME/.cache/cheese-flow/plugins/hallouminate" ]
    [ "$(cat "$TEST_HOME/.cache/ap/plugins/milknado/sentinel")" = "legacy cache sentinel" ]

    # Both live consumers point at the regenerated cache and invoke no `ap`
    # command or old cache path.
    for consumer in "$SCRIPT" "$BEFORE_TEMPLATE" "$AFTER_TEMPLATE"; do
        grep -Fq "\$HOME/.cache/cheese-flow/plugins" "$consumer"
        if grep -Fq "\$HOME/.cache/ap/plugins" "$consumer" \
            || grep -Eq '(^|[[:space:]])ap([[:space:]]|$)' "$consumer"; then
            return 1
        fi
    done
}

@test "git plugin cache publishes immutable generations through stable symlinks" {
    command -v git >/dev/null 2>&1 || skip "git not installed"
    local upstream="$TEST_HOME/upstream" registry="$TEST_HOME/registry.yaml"
    local cache="$TEST_HOME/.cache/cheese-flow/plugins"

    git init -q -b main "$upstream"
    mkdir -p "$upstream/.claude-plugin"
    printf '{"name":"demo"}\n' > "$upstream/.claude-plugin/marketplace.json"
    printf 'first\n' > "$upstream/version"
    git -C "$upstream" add .
    git -C "$upstream" -c user.name=test -c user.email=test@example.com commit -qm first
    printf 'plugins:\n  demo:\n    git: %s\n    branch: main\n' "$upstream" > "$registry"

    run bash -c "source '$CACHE_LIB'; cheese_plugin_cache_prepare '$registry' '$cache'"
    [ "$status" -eq 0 ]
    [ -L "$cache/.current" ]
    [ -L "$cache/demo" ]
    [ "$(readlink "$cache/demo")" = .current/demo ]
    local first_generation
    first_generation=$(readlink "$cache/.current")
    [[ "$first_generation" =~ ^\.generations/[0-9a-f]{40}$ ]]
    [ "$(cat "$cache/demo/version")" = first ]

    printf 'second\n' > "$upstream/version"
    git -C "$upstream" add version
    git -C "$upstream" -c user.name=test -c user.email=test@example.com commit -qm second
    run bash -c "source '$CACHE_LIB'; cheese_plugin_cache_prepare '$registry' '$cache'"
    [ "$status" -eq 0 ]
    local second_generation
    second_generation=$(readlink "$cache/.current")
    [ "$second_generation" != "$first_generation" ]
    [ -d "$cache/$first_generation" ]
    [ "$(cat "$cache/demo/version")" = second ]
}

@test "failed cache preparation preserves the published generation" {
    command -v git >/dev/null 2>&1 || skip "git not installed"
    local upstream="$TEST_HOME/upstream-failure" registry="$TEST_HOME/registry-failure.yaml"
    local cache="$TEST_HOME/.cache/cheese-flow/plugins"

    git init -q -b main "$upstream"
    printf 'stable\n' > "$upstream/version"
    git -C "$upstream" add version
    git -C "$upstream" -c user.name=test -c user.email=test@example.com commit -qm stable
    printf 'plugins:\n  demo:\n    git: %s\n    branch: main\n' "$upstream" > "$registry"
    bash -c "source '$CACHE_LIB'; cheese_plugin_cache_prepare '$registry' '$cache'"
    local published
    published=$(readlink "$cache/.current")

    cat >> "$registry" <<EOF
  broken:
    git: $TEST_HOME/does-not-exist
    branch: main
EOF
    run bash -c "source '$CACHE_LIB'; cheese_plugin_cache_prepare '$registry' '$cache'"
    [ "$status" -ne 0 ]
    [ "$(readlink "$cache/.current")" = "$published" ]
    [ "$(cat "$cache/demo/version")" = stable ]
    [ ! -e "$cache/broken" ]
    [ ! -e "$cache.lock" ]
    run bash -c "compgen -G '$cache.stage.*'"
    [ "$status" -ne 0 ]
}
