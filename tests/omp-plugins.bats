#!/usr/bin/env bats
# Behavioural tests for sync_omp_plugins() in .sync-lib.sh — the reconcile
# that installs milknado + hallouminate as native OMP marketplace plugins from
# the `.omp.plugins` subtree of chezmoi/.chezmoidata/omp.yaml. Idempotent: a
# converged machine makes zero mutating `omp` calls. `.npm[]`-installed
# plugins are never touched — only `.marketplace[]` entries this function owns.
#
# The `omp` CLI is mocked with a recorder that also applies marketplace
# add/remove and install/uninstall to fixture state (~/.omp/marketplaces.json
# and an installed-ids file feeding `omp plugin list --json`), so the
# reconcile flow behaves like the real CLI (same pattern as
# tests/reconcile-claude-mcps.bats).

load test_helper

setup() {
    setup_test_env
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"

    export LIB="$REAL_DOTFILES_DIR/.sync-lib.sh"
    export CALLS="$TEST_HOME/omp-calls.log"
    export MP_JSON="$TEST_HOME/.omp/marketplaces.json"
    export INSTALLED="$TEST_HOME/omp-installed.txt"
    export NPM_JSON="$TEST_HOME/omp-npm.json"
    mkdir -p "$TEST_HOME/.omp"
    : > "$INSTALLED"
    printf '[]' > "$NPM_JSON"

    # Mock omp CLI: records argv; applies marketplace add/remove and plugin
    # install/uninstall to fixture state; plugin list --json reads it back.
    local fake_bin="$TEST_HOME/fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/omp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2 $3" in
    "plugin marketplace add")
        source="$4"
        mp_name="${source##*/}"
        jq --arg n "$mp_name" --arg s "$source" \
            '.marketplaces += [{name:$n, sourceType:"github", sourceUri:$s, catalogPath:"", addedAt:"", updatedAt:""}]' \
            "$MP_JSON" > "$MP_JSON.tmp" && mv "$MP_JSON.tmp" "$MP_JSON"
        exit 0
        ;;
    "plugin marketplace remove")
        mp_name="$4"
        jq --arg n "$mp_name" '.marketplaces |= map(select(.name != $n))' "$MP_JSON" > "$MP_JSON.tmp" && mv "$MP_JSON.tmp" "$MP_JSON"
        exit 0
        ;;
esac
case "$1 $2" in
    "plugin install")
        printf '%s\n' "$3" >> "$INSTALLED"
        exit 0
        ;;
    "plugin uninstall")
        grep -vxF "$3" "$INSTALLED" > "$INSTALLED.tmp" 2>/dev/null
        mv "$INSTALLED.tmp" "$INSTALLED"
        exit 0
        ;;
    "plugin list")
        mp_json=$(jq -Rn '[inputs | select(length>0) | {id: ., scope: "user", entries: [{}]}]' < "$INSTALLED")
        npm_json=$(cat "$NPM_JSON")
        jq -n --argjson mp "$mp_json" --argjson npm "$npm_json" '{npm: $npm, marketplace: $mp}'
        exit 0
        ;;
esac
exit 1
SH
    chmod +x "$fake_bin/omp"
    export PATH="$fake_bin:$PATH"

    # Fixture dotfiles root: minimal omp registry with the two plugins this
    # function owns.
    export FIX="$TEST_HOME/fixture-dotfiles"
    mkdir -p "$FIX/chezmoi/.chezmoidata"
    cat > "$FIX/chezmoi/.chezmoidata/omp.yaml" <<'YAML'
omp:
  plugins:
    milknado:
      marketplace: milknado
      source: paulnsorensen/milknado
    hallouminate:
      marketplace: hallouminate
      source: paulnsorensen/hallouminate
YAML

    seed_marketplaces() {
        printf '{"version":1,"marketplaces":[%s]}' "$1" > "$MP_JSON"
    }
}

teardown() { teardown_test_env; }

mp_entry() {
    local name="$1"
    printf '{"name":"%s","sourceType":"github","sourceUri":"paulnsorensen/%s","catalogPath":"","addedAt":"","updatedAt":""}' "$name" "$name"
}

@test "sync_omp_plugins: converged state makes zero mutating omp calls" {
    seed_marketplaces "$(mp_entry milknado),$(mp_entry hallouminate)"
    printf 'milknado@milknado\nhallouminate@hallouminate\n' > "$INSTALLED"

    run bash -c "source '$LIB'; sync_omp_plugins '$FIX'"
    [ "$status" -eq 0 ]
    ! grep -qE 'marketplace add|marketplace remove| install | uninstall ' "$CALLS"
}

@test "sync_omp_plugins: missing marketplace triggers add then install" {
    seed_marketplaces "$(mp_entry hallouminate)"
    printf 'hallouminate@hallouminate\n' > "$INSTALLED"

    run bash -c "source '$LIB'; sync_omp_plugins '$FIX'"
    [ "$status" -eq 0 ]
    grep -qF "plugin marketplace add paulnsorensen/milknado" "$CALLS"
    grep -qF "plugin install milknado@milknado" "$CALLS"
    jq -e '.marketplaces[] | select(.name == "milknado")' "$MP_JSON" >/dev/null
    grep -qxF "milknado@milknado" "$INSTALLED"
}

@test "sync_omp_plugins: missing plugin (marketplace present) triggers install only" {
    seed_marketplaces "$(mp_entry milknado),$(mp_entry hallouminate)"
    printf 'hallouminate@hallouminate\n' > "$INSTALLED"

    run bash -c "source '$LIB'; sync_omp_plugins '$FIX'"
    [ "$status" -eq 0 ]
    ! grep -q "plugin marketplace add" "$CALLS"
    grep -qF "plugin install milknado@milknado" "$CALLS"
}

@test "sync_omp_plugins: de-listed entry triggers uninstall then marketplace remove" {
    # Registry only lists hallouminate; live machine still has milknado.
    cat > "$FIX/chezmoi/.chezmoidata/omp.yaml" <<'YAML'
omp:
  plugins:
    hallouminate:
      marketplace: hallouminate
      source: paulnsorensen/hallouminate
YAML
    seed_marketplaces "$(mp_entry milknado),$(mp_entry hallouminate)"
    printf 'milknado@milknado\nhallouminate@hallouminate\n' > "$INSTALLED"

    run bash -c "source '$LIB'; sync_omp_plugins '$FIX'"
    [ "$status" -eq 0 ]
    grep -qF "plugin uninstall milknado@milknado" "$CALLS"
    grep -qF "plugin marketplace remove milknado" "$CALLS"
    ! grep -qxF "milknado@milknado" "$INSTALLED"
    ! jq -e '.marketplaces[] | select(.name == "milknado")' "$MP_JSON" >/dev/null
}

@test "sync_omp_plugins: npm-installed plugins are never touched" {
    seed_marketplaces "$(mp_entry milknado),$(mp_entry hallouminate)"
    printf 'milknado@milknado\nhallouminate@hallouminate\n' > "$INSTALLED"
    printf '[{"id":"some-npm-plugin","scope":"user"}]' > "$NPM_JSON"

    run bash -c "source '$LIB'; sync_omp_plugins '$FIX'"
    [ "$status" -eq 0 ]
    ! grep -qF "some-npm-plugin" "$CALLS"
}

@test "sync_omp_plugins: malformed marketplaces.json degrades to empty instead of aborting under set -e" {
    # No .marketplaces key → jq exits non-zero. Unguarded, that killed the
    # whole sync under the caller's `set -e` with no diagnostic; guarded, it
    # warns, treats the file as empty, and re-adds the marketplaces.
    printf '{"version":1}' > "$MP_JSON"
    printf 'milknado@milknado\nhallouminate@hallouminate\n' > "$INSTALLED"

    run bash -ec "source '$LIB'; sync_omp_plugins '$FIX'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"marketplaces.json malformed"* ]]
    grep -qF "plugin marketplace add paulnsorensen/milknado" "$CALLS"
    grep -qF "plugin marketplace add paulnsorensen/hallouminate" "$CALLS"
}

@test "sync_omp_plugins: omp absent from PATH skips cleanly (returns 0)" {
    seed_marketplaces "$(mp_entry milknado),$(mp_entry hallouminate)"
    printf 'milknado@milknado\nhallouminate@hallouminate\n' > "$INSTALLED"

    local minimal="$TEST_HOME/minimal-bin"
    mkdir -p "$minimal"
    for t in bash yq jq sed grep mv cat mkdir printf; do
        [ -e "$minimal/$t" ] && continue
        cmd_path=$(command -v "$t") && ln -s "$cmd_path" "$minimal/$t"
    done

    run bash -c "PATH='$minimal' source '$LIB'; PATH='$minimal' sync_omp_plugins '$FIX'"
    [ "$status" -eq 0 ]
    [ ! -s "$CALLS" ]
}
