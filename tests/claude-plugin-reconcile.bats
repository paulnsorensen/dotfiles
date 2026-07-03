#!/usr/bin/env bats
# Behavioural tests for chezmoi/lib/claude-plugin-reconcile.sh — the
# manifest-tracked prime/prune of native-claude plugin marketplaces in the
# claude CLI runtime state (spec: native-plugin-bridge, Leg 2).
#
# The `claude` CLI is mocked with a recorder that also applies
# `plugin marketplace add/remove` mutations to the fixture
# known_marketplaces.json, so multi-step flows behave like the real CLI.

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export LIB="$REAL_DOTFILES_DIR/chezmoi/lib/claude-plugin-reconcile.sh"
    export KNOWN="$TEST_HOME/.claude/plugins/known_marketplaces.json"
    export MANIFEST="$TEST_HOME/.claude/.chezmoi-plugin-manifest"
    export CALLS="$TEST_HOME/claude-calls.log"
    export CACHE="$TEST_HOME/.cache/ap/plugins"
    mkdir -p "${KNOWN%/*}"
    echo '{}' > "$KNOWN"
    export INSTALLED="$TEST_HOME/.claude/plugins/installed_plugins.json"
    echo '{"version":2,"plugins":{}}' > "$INSTALLED"

    # Mock claude CLI: records argv; applies marketplace add/remove to $KNOWN.
    local fake_bin="$TEST_HOME/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
    "plugin marketplace")
        case "$3" in
            add)
                root="$4"
                name=$(jq -r '.name' "$root/.claude-plugin/marketplace.json")
                jq --arg n "$name" --arg p "$root" \
                    '.[$n] = {source: {source: "directory", path: $p}}' "$KNOWN" > "$KNOWN.tmp" \
                    && mv "$KNOWN.tmp" "$KNOWN"
                ;;
            remove)
                name="$4"
                jq --arg n "$name" 'del(.[$n])' "$KNOWN" > "$KNOWN.tmp" && mv "$KNOWN.tmp" "$KNOWN"
                ;;
        esac
        ;;
    "plugin install")
        id="$3"
        jq --arg id "$id" '.plugins[$id] = [{scope: "user"}]' "$INSTALLED" > "$INSTALLED.tmp" \
            && mv "$INSTALLED.tmp" "$INSTALLED"
        ;;
    "plugin uninstall")
        id="$3"
        jq --arg id "$id" '(.plugins[$id] // []) |= map(select(.scope != "user"))' \
            "$INSTALLED" > "$INSTALLED.tmp" && mv "$INSTALLED.tmp" "$INSTALLED"
        ;;
esac
exit 0
SH
    chmod +x "$fake_bin/claude"
    export PATH="$fake_bin:$PATH"
}

teardown() { teardown_test_env; }

# mk_cache <key> <marketplace-name>: create a plugin cache with a
# marketplace.json carrying the given .name. Echoes the root path.
mk_cache() {
    local name="$2" root="$CACHE/$1"
    mkdir -p "$root/.claude-plugin"
    printf '{"name": "%s"}\n' "$name" > "$root/.claude-plugin/marketplace.json"
    printf '%s' "$root"
}

# desired_entry <key>: one {key, marketplace_root} object for a cached key.
desired_entry() { jq -nc --arg k "$1" --arg r "$CACHE/$1" '{key:$k, marketplace_root:$r}'; }

run_reconcile() {
    run bash -c "source '$LIB' && claude_plugin_reconcile '$1' '$KNOWN' '$MANIFEST'"
}

@test "reconcile: primes desired marketplaces and records the manifest by marketplace name" {
    mk_cache milknado milknado >/dev/null
    # key≠name case: key 'widget', marketplace.json .name 'acme'.
    mk_cache widget acme >/dev/null
    local desired
    desired=$(jq -nc --argjson a "$(desired_entry milknado)" --argjson b "$(desired_entry widget)" '[$a, $b]')
    run_reconcile "$desired"
    [ "$status" -eq 0 ]
    # Both marketplaces primed by root.
    grep -q "plugin marketplace add $CACHE/milknado" "$CALLS"
    grep -q "plugin marketplace add $CACHE/widget" "$CALLS"
    # Manifest holds canonical names (acme, not widget), sorted, deduped.
    diff <(printf 'acme\nmilknado\n') "$MANIFEST"
    # The mock indexed both into the known file under their names.
    [ "$(jq -r '.acme.source.path' "$KNOWN")" = "$CACHE/widget" ]
}

@test "reconcile: missing cache marketplace.json warns and skips without failing" {
    mk_cache milknado milknado >/dev/null
    # 'ghost' has no cache dir at all.
    local desired
    desired=$(jq -nc --argjson a "$(desired_entry milknado)" --argjson g "$(desired_entry ghost)" '[$a, $g]')
    run_reconcile "$desired"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ghost"* ]]
    [[ "$output" == *"marketplace.json"* ]]
    # milknado still primed; ghost never added; manifest holds only milknado.
    grep -q "plugin marketplace add $CACHE/milknado" "$CALLS"
    run grep -q "ghost" "$CALLS"; [ "$status" -ne 0 ]
    diff <(printf 'milknado\n') "$MANIFEST"
}

@test "reconcile: prunes a manifest-owned marketplace that dropped from desired" {
    mk_cache milknado milknado >/dev/null
    mkdir -p "${MANIFEST%/*}"
    printf 'gone\nmilknado\n' > "$MANIFEST"
    run_reconcile "$(jq -nc --argjson a "$(desired_entry milknado)" '[$a]')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removing retired marketplace: gone"* ]]
    grep -q "plugin marketplace remove gone" "$CALLS"
    # milknado kept (still desired), gone removed from the manifest.
    diff <(printf 'milknado\n') "$MANIFEST"
}

@test "reconcile: never removes a non-owned marketplace; NOTEs dead directory sources" {
    # A live known file with two directory sources this reconcile never added:
    # 'easy-cheese' whose path is gone, 'todoist-flow' whose path still exists.
    local livedir="$TEST_HOME/live-todoist"
    mkdir -p "$livedir"
    jq -n --arg p "$livedir" '{
        "easy-cheese": {source: {source: "directory", path: "/nope/easy-cheese"}},
        "todoist-flow": {source: {source: "directory", path: $p}},
        "claude-plugins-official": {source: {source: "github", repo: "anthropics/x"}}
    }' > "$KNOWN"
    run_reconcile '[]'
    [ "$status" -eq 0 ]
    # Dead directory source surfaced as a NOTE with a hand-cleanup command.
    [[ "$output" == *"NOTE:"* ]]
    [[ "$output" == *"easy-cheese"* ]]
    # Never removed — no remove call, still present in the known file.
    run grep -q "marketplace remove" "$CALLS"; [ "$status" -ne 0 ]
    jq -e '."easy-cheese"' "$KNOWN" >/dev/null
    # Live directory source with an existing path is NOT NOTEd; github source
    # (no path) is never NOTEd.
    [[ "$output" != *"todoist-flow"* ]]
    [[ "$output" != *"claude-plugins-official"* ]]
}

@test "reconcile: missing claude CLI warns and exits 0 without writing the manifest" {
    mk_cache milknado milknado >/dev/null
    local minimal="$TEST_HOME/minimal-bin"
    mkdir -p "$minimal"
    for t in bash jq dirname mkdir sort; do
        ln -s "$(command -v $t)" "$minimal/$t" 2>/dev/null || true
    done
    run bash -c "PATH='$minimal' bash -c \"source '$LIB' && claude_plugin_reconcile '$(jq -nc --argjson a "$(desired_entry milknado)" '[$a]')' '$KNOWN' '$MANIFEST'\""
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude CLI not found"* ]]
    [ ! -f "$MANIFEST" ]
}

@test "reconcile: runs under /bin/bash 3.2 with an empty desired set (macOS chezmoi shell)" {
    # No mapfile, guarded empty-array expansions: must not crash under set -u.
    printf 'stale\n' > "$MANIFEST"
    mkdir -p "${MANIFEST%/*}"
    printf 'stale\n' > "$MANIFEST"
    run /bin/bash -c "set -euo pipefail; source '$LIB' && claude_plugin_reconcile '[]' '$KNOWN' '$MANIFEST'"
    [ "$status" -eq 0 ]
    # 'stale' was manifest-owned and no longer desired → pruned; manifest empty.
    [ -z "$(grep -v '^$' "$MANIFEST" || true)" ]
}

run_reconcile_installed() {
    run bash -c "source '$LIB' && claude_plugin_reconcile '$1' '$KNOWN' '$MANIFEST' '$INSTALLED'"
}

@test "reconcile: installs a desired plugin at user scope and skips one already user-installed" {
    mk_cache milknado milknado >/dev/null
    mk_cache widget acme >/dev/null
    # widget@acme already user-installed; milknado@milknado not yet installed.
    jq -n '{version:2, plugins:{"widget@acme":[{scope:"user"}]}}' > "$INSTALLED"
    local desired
    desired=$(jq -nc --argjson a "$(desired_entry milknado)" --argjson b "$(desired_entry widget)" '[$a, $b]')
    run_reconcile_installed "$desired"
    [ "$status" -eq 0 ]
    # Missing install performed by id; already-installed one skipped.
    grep -q "plugin install milknado@milknado" "$CALLS"
    run grep -q "plugin install widget@acme" "$CALLS"; [ "$status" -ne 0 ]
    # The mock recorded milknado as user-installed.
    [ "$(jq -r '.plugins["milknado@milknado"][0].scope' "$INSTALLED")" = "user" ]
}

@test "reconcile: uninstalls a retired user-scope plugin whose marketplace the manifest owns" {
    mk_cache milknado milknado >/dev/null
    mkdir -p "${MANIFEST%/*}"
    # Manifest proves we previously added both the milknado and oldmkt markets.
    printf 'milknado\noldmkt\n' > "$MANIFEST"
    jq -n '{version:2, plugins:{
        "oldplug@oldmkt":  [{scope:"user"}],
        "milknado@milknado":[{scope:"user"}],
        "handmade@other":  [{scope:"user"}]
    }}' > "$INSTALLED"
    run_reconcile_installed "$(jq -nc --argjson a "$(desired_entry milknado)" '[$a]')"
    [ "$status" -eq 0 ]
    # Retired + manifest-owned marketplace → uninstalled at user scope.
    grep -q "plugin uninstall oldplug@oldmkt --scope user" "$CALLS"
    # Still desired → kept.
    run grep -q "uninstall milknado@milknado" "$CALLS"; [ "$status" -ne 0 ]
    # Marketplace 'other' is not manifest-owned → never uninstalled.
    run grep -q "uninstall handmade@other" "$CALLS"; [ "$status" -ne 0 ]
}

@test "reconcile: never touches project-scope installs; NOTEs a dead projectPath" {
    mk_cache milknado milknado >/dev/null
    mkdir -p "${MANIFEST%/*}"
    printf 'milknado\nhallouminate\n' > "$MANIFEST"
    # hallouminate@hallouminate installed at project scope with a dead path.
    jq -n '{version:2, plugins:{
        "hallouminate@hallouminate":[{scope:"project", projectPath:"/nope/tdbr"}]
    }}' > "$INSTALLED"
    run_reconcile_installed "$(jq -nc --argjson a "$(desired_entry milknado)" '[$a]')"
    [ "$status" -eq 0 ]
    # Project scope surfaced as a NOTE, with the exact hand-cleanup command.
    [[ "$output" == *"NOTE:"* ]]
    [[ "$output" == *"hallouminate@hallouminate"* ]]
    [[ "$output" == *"--scope project"* ]]
    # Never uninstalled by this reconcile.
    run grep -q "plugin uninstall hallouminate" "$CALLS"; [ "$status" -ne 0 ]
}
