#!/usr/bin/env bats
# Tests for bin/lib/vault.sh — detection precedence, materialize failure
# modes, cache atomicity/permissions, loader parity across the three bash
# loaders, and packages/sync.sh's gate_unless suppression of bws.
#
# shellcheck disable=SC1090,SC2016,SC2034
#   SC1090: $VAULT_LIB is a runtime-computed fixture path
#   SC2016: single-quoted 'sh -c "$VAR"' bodies must expand in the child
#   SC2034: unused read placeholders in the packages.yaml TSV gate fixture

load test_helper

VAULT_LIB="$REAL_DOTFILES_DIR/bin/lib/vault.sh"

setup() {
    setup_test_env
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
}

teardown() {
    teardown_test_env
}

# ── detection precedence ──

@test "vault_detect: op present wins over bws" {
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/op" "$MOCK_BIN/bws"

    source "$VAULT_LIB"
    run vault_detect
    [ "$status" -eq 0 ]
    [ "$output" = "onepassword" ]
}

@test "vault_detect: bws wins when op is absent" {
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/bws"

    source "$VAULT_LIB"
    run vault_detect
    [ "$status" -eq 0 ]
    [ "$output" = "bitwarden" ]
}

@test "vault_detect: neither op nor bws present fails naming bin/vault-provision" {
    run env PATH="$MOCK_BIN:/usr/bin:/bin" bash -c "source '$VAULT_LIB'; vault_detect"
    [ "$status" -ne 0 ]
    [[ "$output" == *"bin/vault-provision"* ]]
}

# ── vault_token ──

@test "vault_token: missing Keychain item fails naming bin/vault-provision" {
    cat > "$MOCK_BIN/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$MOCK_BIN/security"

    source "$VAULT_LIB"
    run vault_token
    [ "$status" -ne 0 ]
    [[ "$output" == *"bin/vault-provision"* ]]
}

# ── vault_materialize ──

_setup_materialize_fixture() {
    export DOTFILES_DIR="$TEST_HOME/dotfiles"
    mkdir -p "$DOTFILES_DIR/secrets"
    printf 'FOO_KEY=\nBAR_KEY=\n' > "$DOTFILES_DIR/secrets/secrets.env.tmpl"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/op"
}

@test "vault_materialize: rejects a response missing a required key" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "source '$VAULT_LIB'; vault_materialize"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing/empty keys"* ]]
    [[ "$output" == *"BAR_KEY"* ]]

    source "$VAULT_LIB"
    local cache_dir
    cache_dir="$(dirname "$(vault_secrets_file)")"
    run bash -c "ls '$cache_dir'/secrets.env.* 2>/dev/null"
    [ -z "$output" ]
}

@test "vault_materialize: rejects a response with an unlisted key" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nBAR_KEY=bar\nEVIL_KEY=oops\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "source '$VAULT_LIB'; vault_materialize"
    [ "$status" -ne 0 ]

    source "$VAULT_LIB"
    run cat "$(vault_secrets_file)"
    [[ "$output" != *"EVIL_KEY"* ]]
}

@test "vault_materialize: rejects a response whose value split across a newline" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nbar\nBAR_KEY=bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "source '$VAULT_LIB'; vault_materialize"
    [ "$status" -ne 0 ]
}

@test "materialize: leaked RETURN trap doesn't kill a caller with frames on the stack (B1 regression)" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nBAR_KEY=bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "
        set -euo pipefail
        source '$VAULT_LIB'
        wrapper() {
            DOTFILES_DIR='$DOTFILES_DIR' vault_materialize
        }
        wrapper
        echo AFTER_WRAPPER
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"AFTER_WRAPPER"* ]]
}

@test "vault_materialize: rejects a response with an empty value" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nBAR_KEY=\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "source '$VAULT_LIB'; vault_materialize"
    [ "$status" -ne 0 ]
    [[ "$output" == *"BAR_KEY"* ]]
}

@test "vault_materialize: failed materialize leaves the prior cache byte-identical" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\n'
EOF
    chmod +x "$MOCK_BIN/op"

    source "$VAULT_LIB"
    local cache
    cache="$(vault_secrets_file)"
    mkdir -p "$(dirname "$cache")"
    printf 'SENTINEL=untouched\n' > "$cache"

    run bash -c "source '$VAULT_LIB'; vault_materialize"
    [ "$status" -ne 0 ]
    [ "$(cat "$cache")" = "SENTINEL=untouched" ]
}

@test "vault_materialize: cache file mode is 0600" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nBAR_KEY=bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "source '$VAULT_LIB'; vault_materialize"
    [ "$status" -eq 0 ]

    source "$VAULT_LIB"
    local cache mode
    cache="$(vault_secrets_file)"
    if [[ "$(uname)" == "Darwin" ]]; then
        mode="$(stat -f %Lp "$cache")"
    else
        mode="$(stat -c %a "$cache")"
    fi
    [ "$mode" = "600" ]
}

# ── loader parity ──

@test "loader parity: bin/lib/vault.sh's own cache path resolves a cache-only key" {
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    mkdir -p "$XDG_CACHE_HOME/dotfiles"
    printf 'CACHE_ONLY_KEY=vlib\n' > "$XDG_CACHE_HOME/dotfiles/secrets.env"

    source "$VAULT_LIB"
    run cat "$(vault_secrets_file)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CACHE_ONLY_KEY=vlib"* ]]
}

@test "loader parity: zsh/core.zsh sources a cache-only key" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    mkdir -p "$XDG_CACHE_HOME/dotfiles"
    printf 'CACHE_ONLY_KEY=zsh\n' > "$XDG_CACHE_HOME/dotfiles/secrets.env"

    run zsh -fc "export DOTFILES_DIR='$REAL_DOTFILES_DIR' XDG_CACHE_HOME='$XDG_CACHE_HOME' HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/core.zsh'; printf '%s' \"\$CACHE_ONLY_KEY\""
    [ "$status" -eq 0 ]
    [ "$output" = "zsh" ]
}

@test "loader parity: bin/cc-env-exec exports a cache-only key" {
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    mkdir -p "$XDG_CACHE_HOME/dotfiles"
    printf 'CACHE_ONLY_KEY=ccenv\n' > "$XDG_CACHE_HOME/dotfiles/secrets.env"
    export DOTFILES_DIR="$REAL_DOTFILES_DIR"

    run "$REAL_DOTFILES_DIR/bin/cc-env-exec" sh -c 'printf %s "$CACHE_ONLY_KEY"'
    [ "$status" -eq 0 ]
    [ "$output" = "ccenv" ]
}

# ── gate_unless (packages/sync.sh cargo query + filter) ──

@test "gate_unless: bws is suppressed when ONEPASSWORD_PRESENT=true, kept when unset" {
    local fixture="$TEST_HOME/packages.yaml"
    cat > "$fixture" <<'YAML'
packages:
  - cargo-update: { source: cargo, version: "22.1.0" }
  - bws: { source: cargo, version: "2.1.0", gate_unless: ONEPASSWORD_PRESENT }
YAML

    local query='.packages[] | select(kind == "map") | to_entries[0] | select(.value.source == "cargo") | [.key, (.value.git // ""), (.value.branch // ""), (.value.version // ""), (.value.rev // ""), (.value.gate_unless // "")] | join("|")'

    unset ONEPASSWORD_PRESENT
    local names=()
    while IFS='|' read -r name git_url branch version rev gate; do
        [[ -z "$name" ]] && continue
        if [[ -n "$gate" && "${!gate:-false}" == "true" ]]; then
            continue
        fi
        names+=("$name")
    done < <(yq -r "$query" "$fixture")
    [[ " ${names[*]} " == *" cargo-update "* ]]
    [[ " ${names[*]} " == *" bws "* ]]

    export ONEPASSWORD_PRESENT=true
    names=()
    while IFS='|' read -r name git_url branch version rev gate; do
        [[ -z "$name" ]] && continue
        if [[ -n "$gate" && "${!gate:-false}" == "true" ]]; then
            continue
        fi
        names+=("$name")
    done < <(yq -r "$query" "$fixture")
    [[ " ${names[*]} " == *" cargo-update "* ]]
    [[ " ${names[*]} " != *" bws "* ]]
}
