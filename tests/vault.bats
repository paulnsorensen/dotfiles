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
    [[ "$output" == *"unexpected or malformed entry"* ]]

    source "$VAULT_LIB"
    [ ! -e "$(vault_secrets_file)" ]
}

@test "vault_materialize: fails loudly under /bin/bash 3.2 instead of corrupting the cache" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nBAR_KEY=bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    [ -x /bin/bash ] || skip "/bin/bash not present on this host"
    local sys_bash_major
    sys_bash_major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]:-0}"')"
    (( sys_bash_major < 4 )) || skip "/bin/bash is ${sys_bash_major}.x; this guard only trips on bash 3.2"

    run /bin/bash -c "source '$VAULT_LIB'; vault_materialize"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires bash >= 4"* ]]

    source "$VAULT_LIB"
    [ ! -e "$(vault_secrets_file)" ]
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

@test "materialize_secrets: real caller (.sync-lib.sh) survives a wrapper frame under set -euo pipefail" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nBAR_KEY=bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "
        set -euo pipefail
        dir='$REAL_DOTFILES_DIR'
        source '$VAULT_LIB'
        source '$REAL_DOTFILES_DIR/.sync-lib.sh'
        SYNC_FAILURES=()
        wrapper() {
            DOTFILES_DIR='$DOTFILES_DIR' materialize_secrets
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

# ── headless-Linux token storage ──
#
# vault_token branches on `uname -s`; these mock uname to exercise the Linux
# path on any host. A headless box has no keyring daemon, so the token is a
# 0600 file and the mode check is the only thing standing between a readable
# token and a leaked one.

mock_linux_uname() {
    cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-s" ]] && echo Linux || echo Linux
EOF
    chmod +x "$MOCK_BIN/uname"
}

@test "vault_token: on Linux reads the 0600 token file" {
    mock_linux_uname
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf 'tok-abc123\n' > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 600 "$XDG_CONFIG_HOME/dotfiles/bws-token"

    source "$VAULT_LIB"
    run vault_token
    [ "$status" -eq 0 ]
    [ "$output" = "tok-abc123" ]
}

@test "vault_token: on Linux refuses a group/world-readable token file" {
    mock_linux_uname
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf 'tok-abc123\n' > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 644 "$XDG_CONFIG_HOME/dotfiles/bws-token"

    source "$VAULT_LIB"
    run vault_token
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be mode 600"* ]]
    # the secret itself must never be echoed on the refusal path
    [[ "$output" != *"tok-abc123"* ]]
}

@test "vault_token: on Linux a missing token file names bin/vault-provision" {
    mock_linux_uname
    export XDG_CONFIG_HOME="$TEST_HOME/.config"

    source "$VAULT_LIB"
    run vault_token
    [ "$status" -ne 0 ]
    [[ "$output" == *"bin/vault-provision"* ]]
}

# ── bootstrap split: unprovisioned vs provisioned-but-broken ──

@test "vault_provisioned: false when bws exists but no token is stored" {
    mock_linux_uname
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/bws"
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    export BWS_PROJECT_ID=proj-1

    source "$VAULT_LIB"
    run vault_provisioned
    [ "$status" -ne 0 ]
}

@test "vault_provisioned: false when a token exists but BWS_PROJECT_ID is unset" {
    mock_linux_uname
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/bws"
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf 'tok\n' > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 600 "$XDG_CONFIG_HOME/dotfiles/bws-token"
    unset BWS_PROJECT_ID

    source "$VAULT_LIB"
    run vault_provisioned
    [ "$status" -ne 0 ]
}

@test "vault_provisioned: true once token and project id are both present" {
    mock_linux_uname
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/bws"
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf 'tok\n' > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 600 "$XDG_CONFIG_HOME/dotfiles/bws-token"
    export BWS_PROJECT_ID=proj-1

    source "$VAULT_LIB"
    run vault_provisioned
    [ "$status" -eq 0 ]
}

@test "vault_provisioned: true when the project id is only in the toggles file, not the env" {
    # Regression: vault_materialize falls back to reading BWS_PROJECT_ID from
    # the toggles file. If vault_provisioned only consulted the environment, a
    # provisioned machine would be judged unprovisioned and sync would SKIP
    # materialization silently, serving a stale cache forever.
    mock_linux_uname
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/bws"
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf 'tok\n' > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 600 "$XDG_CONFIG_HOME/dotfiles/bws-token"

    export DOTFILES_DIR="$TEST_HOME/dotfiles"
    mkdir -p "$DOTFILES_DIR"
    printf 'DOTFILES_DEV=false\nBWS_PROJECT_ID=proj-from-file\n' > "$DOTFILES_DIR/.env"
    unset BWS_PROJECT_ID

    source "$VAULT_LIB"
    run vault_provisioned
    [ "$status" -eq 0 ]

    run _vault_project_id
    [ "$output" = "proj-from-file" ]
}

@test "vault_provisioned: true for 1Password without any bws token or project id" {
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/op"
    unset BWS_PROJECT_ID

    source "$VAULT_LIB"
    run vault_provisioned
    [ "$status" -eq 0 ]
}
