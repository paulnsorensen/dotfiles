#!/usr/bin/env bats
# Tests for bin/lib/vault.sh — provider resolution, materialize failure modes,
# cache provenance/atomicity/permissions, and loader parity.
#
# shellcheck disable=SC1090,SC2016,SC2030,SC2031
#   SC1090: $VAULT_LIB is a runtime-computed fixture path
#   SC2016: single-quoted 'sh -c "$VAR"' bodies must expand in the child
#   SC2030/SC2031: Bats runs each @test in its own intentional subshell
load test_helper

setup() {
    setup_test_env
    export VAULT_LIB="$REAL_DOTFILES_DIR/bin/lib/vault.sh"
    export DOTFILES_DIR="$TEST_HOME/dotfiles"
    export MOCK_BIN="$TEST_HOME/bin"
    mkdir -p "$DOTFILES_DIR" "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"
    unset BWS_PROJECT_ID DOTFILES_OP_ITEM DOTFILES_VAULT_PROVIDER OP_READY
}

teardown() {
    teardown_test_env
}

# ── provider resolution ──

mock_op_readiness() {
    export OP_READY="$1"
    export OP_CALLS="$TEST_HOME/op-calls"
    : > "$OP_CALLS"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OP_CALLS"
[[ "$1" == item && "$2" == get && "$3" == dotfiles
    && "$4" == --vault && "$5" == Employee
    && "$6" == --format && "$7" == json
    && "$OP_READY" == true ]]
EOF
    chmod +x "$MOCK_BIN/op"
}

prepare_bitwarden_readiness() {
    mock_linux_uname
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/bws"
    export BWS_PROJECT_ID=proj-1
    export BWS_FIXTURE_TOKEN=fixture-bws-access-token
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf '%s\n' "$BWS_FIXTURE_TOKEN" > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 600 "$XDG_CONFIG_HOME/dotfiles/bws-token"
}

mock_unready_providers() {
    printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_BIN/op"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_BIN/bws"
    chmod +x "$MOCK_BIN/op" "$MOCK_BIN/bws"
}

wait_for_vault_marker() {
    local marker="$1" pid="$2"
    while [[ ! -e "$marker" ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" || true
            printf 'vault test process %s exited before creating %s\n' \
                "$pid" "$marker" >&2
            return 1
        fi
        sleep 0.01
    done
}

@test "vault_resolve: machine-local Employee item selects ready 1Password" {
    mock_op_readiness true
    cat > "$DOTFILES_DIR/.env" <<'EOF'
DOTFILES_VAULT_PROVIDER=onepassword
DOTFILES_OP_ITEM=op://Employee/dotfiles
EOF

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -eq 0 ]
    [ "$output" = "onepassword" ]
    [ "$(<"$OP_CALLS")" = "item get dotfiles --vault Employee --format json" ]
}

@test "vault_resolve: explicit 1Password failure never falls through to ready Bitwarden" {
    mock_op_readiness false
    prepare_bitwarden_readiness
    export DOTFILES_VAULT_PROVIDER=onepassword
    export DOTFILES_OP_ITEM=op://Employee/dotfiles

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -ne 0 ]
    [[ "$output" == *"onepassword"* ]]
    [[ "$output" == *"op://Employee/dotfiles"* ]]
    [ "$(<"$OP_CALLS")" = "item get dotfiles --vault Employee --format json" ]
}

@test "vault_resolve: explicit 1Password without op names the missing CLI" {
    export DOTFILES_VAULT_PROVIDER=onepassword
    export DOTFILES_OP_ITEM=op://Employee/dotfiles

    run env PATH="$MOCK_BIN:/usr/bin:/bin" "$BASH" -c "source '$VAULT_LIB'; vault_resolve"

    assert_failure
    assert_output_contains "1Password CLI"
    assert_output_contains "op"
    assert_output_not_contains "item 'op://Employee/dotfiles' is not accessible"
}

@test "vault_resolve: explicit unready provider preserves only same-source cache" {
    mock_op_readiness false
    export DOTFILES_VAULT_PROVIDER=onepassword
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    source "$VAULT_LIB"

    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=old\n' > "$cache"
    local expected
    expected="$(<"$cache")"
    run vault_resolve
    [ "$status" -ne 0 ]
    [ "$(<"$cache")" = "$expected" ]

    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=old\n' > "$cache"
    run vault_resolve
    [ "$status" -ne 0 ]
    [ ! -e "$cache" ]
}

@test "vault_resolve: explicit Bitwarden ignores installed 1Password" {
    mock_op_readiness true
    prepare_bitwarden_readiness
    export DOTFILES_VAULT_PROVIDER=bitwarden
    export DOTFILES_OP_ITEM=not-a-reference

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -eq 0 ]
    [ "$output" = "bitwarden" ]
    [ ! -s "$OP_CALLS" ]
}

@test "vault_resolve: explicit unready Bitwarden neither probes 1Password nor mutates a same-source cache" {
    mock_op_readiness true
    mock_linux_uname
    export DOTFILES_VAULT_PROVIDER=bitwarden
    export BWS_PROJECT_ID=proj-1
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/bws"

    local cache="$HOME/.cache/dotfiles/secrets.env"
    local before="$TEST_HOME/cache-before"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=bitwarden\n# vault-source=proj-1\nFOO_KEY=old\n' > "$cache"
    cp "$cache" "$before"

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -eq 1 ]
    assert_output_contains "configured bitwarden provider is not ready"
    assert_output_not_contains "onepassword"
    [ ! -s "$OP_CALLS" ]
    cmp -s "$cache" "$before"
}

@test "vault_resolve: auto selects the only ready provider" {
    mock_op_readiness true
    export DOTFILES_VAULT_PROVIDER=auto
    export DOTFILES_OP_ITEM=op://Employee/dotfiles

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -eq 0 ]
    [ "$output" = "onepassword" ]
}

@test "vault_resolve: auto selects ready Bitwarden when 1Password is absent" {
    prepare_bitwarden_readiness
    export DOTFILES_VAULT_PROVIDER=auto
    export PATH="$MOCK_BIN:/usr/bin:/bin"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$MOCK_BIN/op"

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -eq 0 ]
    [ "$output" = "bitwarden" ]
}

@test "vault_resolve: auto rejects two ready providers as ambiguous" {
    mock_op_readiness true
    prepare_bitwarden_readiness
    export DOTFILES_VAULT_PROVIDER=auto
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf 'FOO_KEY=legacy\n' > "$cache"

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -ne 0 ]
    [[ "$output" == *"both onepassword and bitwarden are ready"* ]]
    [[ "$output" == *"DOTFILES_VAULT_PROVIDER"* ]]
    [ ! -e "$cache" ]

    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=current\n' > "$cache"
    local expected
    expected="$(<"$cache")"
    run vault_resolve
    [ "$status" -ne 0 ]
    [ "$(<"$cache")" = "$expected" ]
}

@test "vault_resolve: auto with no ready provider and no cache is unconfigured" {
    export DOTFILES_VAULT_PROVIDER=auto
    mock_unready_providers

    run env PATH="$MOCK_BIN:/usr/bin:/bin" "$BASH" -c "source '$VAULT_LIB'; vault_resolve"

    [ "$status" -eq 0 ]
    [ "$output" = "unconfigured" ]
}

@test "vault_resolve: auto with no ready provider preserves a same-source tagged cache and fails" {
    export DOTFILES_VAULT_PROVIDER=auto
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Employee/dotfiles
FOO_KEY=old
BAR_KEY=old
EOF
    local expected
    expected=$(<"$cache")

    mock_unready_providers
    run env PATH="$MOCK_BIN:/usr/bin:/bin" "$BASH" -c "source '$VAULT_LIB'; vault_resolve"

    [ "$status" -ne 0 ]
    [[ "$output" == *"no vault provider is ready"* ]]
    [ "$(<"$cache")" = "$expected" ]
}

@test "vault_resolve: auto invalidates a changed-source cache and becomes unconfigured" {
    export DOTFILES_VAULT_PROVIDER=auto
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=old\n' > "$cache"

    mock_unready_providers
    run env PATH="$MOCK_BIN:/usr/bin:/bin" "$BASH" -c "source '$VAULT_LIB'; vault_resolve"
    assert_success
    [ "$output" = "unconfigured" ]
    [ ! -e "$cache" ]
}

@test "vault_resolve: auto invalidates a legacy cache and becomes unconfigured" {
    export DOTFILES_VAULT_PROVIDER=auto
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf 'FOO_KEY=old\n' > "$cache"

    mock_unready_providers
    run env PATH="$MOCK_BIN:/usr/bin:/bin" "$BASH" -c "source '$VAULT_LIB'; vault_resolve"
    assert_success
    [ "$output" = "unconfigured" ]
    [ ! -e "$cache" ]
}

@test "vault_resolve: source change while probing preserves a freshly tagged current cache" {
    unset DOTFILES_OP_ITEM DOTFILES_VAULT_PROVIDER
    export CONTROL="$TEST_HOME/resolve-control"
    mkdir -p "$CONTROL"
    cat > "$DOTFILES_DIR/.env" <<'EOF'
DOTFILES_VAULT_PROVIDER=auto
DOTFILES_OP_ITEM=op://Old/dotfiles
EOF
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "item get dotfiles --vault Old --format json" ]] || exit 64
: > "$CONTROL/probe-started"
while [[ ! -e "$CONTROL/release-probe" ]]; do
    /bin/sleep 0.01
done
exit 1
EOF
    printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK_BIN/bws"
    chmod +x "$MOCK_BIN/op" "$MOCK_BIN/bws"

    local cache pid resolver_status expected
    cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    "$BASH" -c "source '$VAULT_LIB'; vault_resolve" \
        > "$CONTROL/resolver-output" 2>&1 &
    pid=$!
    wait_for_vault_marker "$CONTROL/probe-started" "$pid"

    cat > "$DOTFILES_DIR/.env" <<'EOF'
DOTFILES_VAULT_PROVIDER=auto
DOTFILES_OP_ITEM=op://New/dotfiles
EOF
    expected=$'# vault-provider=onepassword\n# vault-source=op://New/dotfiles\nFOO_KEY=fresh'
    printf '%s\n' "$expected" > "$cache"
    : > "$CONTROL/release-probe"

    if wait "$pid"; then
        resolver_status=0
    else
        resolver_status=$?
    fi
    [ "$resolver_status" -ne 0 ]
    [ "$(<"$cache")" = "$expected" ]
    [[ "$(<"$CONTROL/resolver-output")" == *"changed during resolution; retry"* ]]
}

@test "vault_resolve: invalid provider setting fails with the accepted values" {
    export DOTFILES_VAULT_PROVIDER=typo
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=stale\n' > "$cache"

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -ne 0 ]
    [[ "$output" == *"auto, onepassword, or bitwarden"* ]]
    [ ! -e "$cache" ]
}

@test "vault_resolve: malformed 1Password item invalidates stale cache before failing" {
    mock_op_readiness true
    export DOTFILES_VAULT_PROVIDER=onepassword
    export DOTFILES_OP_ITEM=Employee/dotfiles
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=old\n' > "$cache"

    source "$VAULT_LIB"
    run vault_resolve

    [ "$status" -ne 0 ]
    [[ "$output" == *"op://<vault>/<item>"* ]]
    [ ! -s "$OP_CALLS" ]
    [ ! -e "$cache" ]
}

@test "vault_resolve: native cache lock serializes concurrent transactions" {
    export DOTFILES_VAULT_PROVIDER=onepassword
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    export CONTROL="$TEST_HOME/resolver-lock-control"
    export OP_CALLS="$CONTROL/op-calls"
    local owner_pid owner_status cache lock mode
    source "$VAULT_LIB"
    cache="$(vault_secrets_file)"
    lock="${cache}.lock"
    mkdir -p "$CONTROL"
    : > "$OP_CALLS"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == item && "$2" == get ]] || exit 64
printf '%s\n' "${LOCK_ROLE:-contender}" >> "$OP_CALLS"
if [[ "${LOCK_ROLE:-}" == owner ]]; then
    : > "$CONTROL/owner-started"
    while [[ ! -e "$CONTROL/release-owner" ]]; do
        /bin/sleep 0.01
    done
fi
printf '{}\n'
EOF
    chmod +x "$MOCK_BIN/op"

    LOCK_ROLE=owner "$BASH" -c "source '$VAULT_LIB'; vault_resolve" \
        > "$CONTROL/owner-output" 2>&1 &
    owner_pid=$!
    wait_for_vault_marker "$CONTROL/owner-started" "$owner_pid"

    run env _VAULT_LOCK_TIMEOUT=0 LOCK_ROLE=contender \
        "$BASH" -c "source '$VAULT_LIB'; vault_resolve"

    assert_failure
    [ "$output" = "vault: timed out waiting for cache lock $lock; another vault transaction is still active." ]
    [ "$(<"$OP_CALLS")" = owner ]

    : > "$CONTROL/release-owner"
    if wait "$owner_pid"; then
        owner_status=0
    else
        owner_status=$?
    fi
    [ "$owner_status" -eq 0 ]
    [ "$(<"$CONTROL/owner-output")" = onepassword ]

    run env _VAULT_LOCK_TIMEOUT=0 LOCK_ROLE=contender \
        "$BASH" -c "source '$VAULT_LIB'; vault_resolve"

    assert_success
    [ "$output" = onepassword ]
    [ "$(<"$OP_CALLS")" = $'owner\ncontender' ]
    [ -f "$lock" ]
    mode="$(stat -c '%a' "$lock" 2>/dev/null || stat -f '%Lp' "$lock")"
    [ "$mode" = 600 ]
}

@test "vault_disables_bitwarden_install: explicit intent wins and auto follows op presence" {
    source "$VAULT_LIB"

    export DOTFILES_VAULT_PROVIDER=onepassword
    run vault_disables_bitwarden_install
    [ "$status" -eq 0 ]

    export DOTFILES_VAULT_PROVIDER=bitwarden
    run vault_disables_bitwarden_install
    [ "$status" -eq 1 ]

    run env PATH="$MOCK_BIN" DOTFILES_VAULT_PROVIDER=auto \
        "$BASH" -c "source '$VAULT_LIB'; vault_disables_bitwarden_install"
    [ "$status" -eq 1 ]

    export DOTFILES_VAULT_PROVIDER=auto

    mock_op_readiness false
    run vault_disables_bitwarden_install
    [ "$status" -eq 0 ]

    export DOTFILES_VAULT_PROVIDER=typo
    run vault_disables_bitwarden_install
    [ "$status" -eq 2 ]
    [[ "$output" == *"auto, onepassword, or bitwarden"* ]]
}

@test "vault-provision: 1Password intent is reported before requiring bws" {
    run env PATH="/usr/bin:/bin" \
        DOTFILES_VAULT_PROVIDER=onepassword \
        DOTFILES_OP_ITEM=op://Employee/dotfiles \
        "$REAL_DOTFILES_DIR/bin/vault-provision"

    assert_failure
    assert_output_contains "Bitwarden provisioning is disabled"
    assert_output_contains "DOTFILES_OP_ITEM"
    assert_output_not_contains "op://Employee/dotfiles"
    assert_output_not_contains "bws not found"
}

@test "vault library exposes exactly the four sorted public contract functions" {
    run "$BASH" -c "
        source '$VAULT_LIB'
        compgen -A function vault_ | LC_ALL=C sort
    "

    assert_success
    local expected
    expected=$'vault_disables_bitwarden_install\nvault_materialize\nvault_resolve\nvault_secrets_file'
    [ "$output" = "$expected" ]
}

# ── private Bitwarden token reader ──

mock_darwin_uname() {
    cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Darwin\n'
EOF
    chmod +x "$MOCK_BIN/uname"
}

@test "_vault_token: missing Darwin Keychain item names bin/vault-provision" {
    mock_darwin_uname
    export USER=fixture-user
    cat > "$MOCK_BIN/security" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "find-generic-password -w -s BWS_ACCESS_TOKEN -a fixture-user" ]] || exit 64
exit 1
EOF
    chmod +x "$MOCK_BIN/security"

    source "$VAULT_LIB"
    run _vault_token

    [ "$status" -eq 1 ]
    assert_output_contains "Bitwarden access token"
    assert_output_contains "bin/vault-provision"
}

@test "_vault_token: Darwin rejects an empty successful Keychain read" {
    mock_darwin_uname
    export USER=fixture-user
    cat > "$MOCK_BIN/security" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "find-generic-password -w -s BWS_ACCESS_TOKEN -a fixture-user" ]] || exit 64
exit 0
EOF
    chmod +x "$MOCK_BIN/security"

    source "$VAULT_LIB"
    run _vault_token

    [ "$status" -eq 1 ]
    assert_output_contains "Bitwarden access token"
    assert_output_contains "bin/vault-provision"
}

@test "vault-provision: empty Darwin token readback fails before exporting to bws" {
    mock_darwin_uname
    export USER=fixture-user
    export SECURITY_CALL_COUNT="$TEST_HOME/security-call-count"
    export BWS_CALLS="$TEST_HOME/bws-calls"
    : > "$BWS_CALLS"
    cat > "$MOCK_BIN/security" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f "$SECURITY_CALL_COUNT" ]] || count="$(<"$SECURITY_CALL_COUNT")"
((count += 1))
printf '%s\n' "$count" > "$SECURITY_CALL_COUNT"
case "$count" in
    1) printf 'fixture-existing-token\n' ;;
    2) exit 0 ;;
    *) exit 99 ;;
esac
EOF
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
printf '<%s>\n' "${BWS_ACCESS_TOKEN-__unset__}" >> "$BWS_CALLS"
exit 99
EOF
    chmod +x "$MOCK_BIN/security" "$MOCK_BIN/bws"

    run "$BASH" -c "printf 'n\n' | env \
        PATH='$MOCK_BIN:/usr/bin:/bin' \
        USER=fixture-user \
        DOTFILES_VAULT_PROVIDER=bitwarden \
        '$REAL_DOTFILES_DIR/bin/vault-provision'"

    [ "$status" -eq 1 ]
    assert_output_contains "could not read the token back from its secure storage"
    assert_output_not_contains "fixture-existing-token"
    [ ! -s "$BWS_CALLS" ]
}

# ── vault_materialize ──

_setup_materialize_fixture() {
    if [[ "${1:-true}" == true ]] && ((BASH_VERSINFO[0] < 4)); then
        skip "vault_materialize requires bash >= 4"
    fi
    export DOTFILES_VAULT_PROVIDER=onepassword
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    mkdir -p "$DOTFILES_DIR/secrets"
    printf 'FOO_KEY=\nBAR_KEY=\n' > "$DOTFILES_DIR/secrets/secrets.env.tmpl"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_BIN/op"
}

@test "vault_materialize: malformed 1Password item invalidates stale cache before failing" {
    _setup_materialize_fixture
    export DOTFILES_OP_ITEM=Employee/dotfiles
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=old\nBAR_KEY=old\n' > "$cache"

    run bash -c "source '$VAULT_LIB'; vault_materialize onepassword"

    assert_failure
    assert_output_contains "op://<vault>/<item>"
    [ ! -e "$cache" ]
}

@test "vault_materialize: missing Bitwarden project invalidates a cross-provider cache" {
    _setup_materialize_fixture
    unset BWS_PROJECT_ID
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=old\nBAR_KEY=old\n' > "$cache"

    run bash -c "source '$VAULT_LIB'; vault_materialize bitwarden"

    assert_failure
    assert_output_contains "BWS_PROJECT_ID"
    [ ! -e "$cache" ]
}

@test "vault_materialize: missing manifest invalidates a wrong-source cache before returning" {
    _setup_materialize_fixture
    local manifest="$DOTFILES_DIR/secrets/secrets.env.tmpl"
    local cache="$HOME/.cache/dotfiles/secrets.env"
    rm "$manifest"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=old\nBAR_KEY=old\n' > "$cache"
    export OP_CALLS="$TEST_HOME/op-calls"
    : > "$OP_CALLS"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$OP_CALLS"
exit 99
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    [ "$output" = "vault: template not found: $manifest"$'\nvault: cache removed because its provider/source provenance no longer matches.' ]
    [ ! -e "$cache" ]
    [ ! -s "$OP_CALLS" ]
}

@test "vault_materialize: nonblank manifest invalidates a wrong-source cache without fetching" {
    _setup_materialize_fixture
    local cache="$HOME/.cache/dotfiles/secrets.env"
    export OP_CALLS="$TEST_HOME/op-calls"
    : > "$OP_CALLS"
    printf 'FOO_KEY=not-blank\nBAR_KEY=\n' > "$DOTFILES_DIR/secrets/secrets.env.tmpl"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=old\nBAR_KEY=old\n' > "$cache"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$OP_CALLS"
exit 99
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    [ "$output" = $'vault: manifest must contain unique KEY= entries with blank values; found a non-blank value.\nvault: cache removed because its provider/source provenance no longer matches.' ]
    [ ! -e "$cache" ]
    [ ! -s "$OP_CALLS" ]
}

@test "vault_materialize: duplicate manifest key invalidates a wrong-source cache without fetching" {
    _setup_materialize_fixture
    local cache="$HOME/.cache/dotfiles/secrets.env"
    export OP_CALLS="$TEST_HOME/op-calls"
    : > "$OP_CALLS"
    printf 'FOO_KEY=\nBAR_KEY=\nFOO_KEY=\n' > "$DOTFILES_DIR/secrets/secrets.env.tmpl"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=old\nBAR_KEY=old\n' > "$cache"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$OP_CALLS"
exit 99
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    [ "$output" = $'vault: manifest must contain unique KEY= entries with blank values; found a duplicate key.\nvault: cache removed because its provider/source provenance no longer matches.' ]
    [ ! -e "$cache" ]
    [ ! -s "$OP_CALLS" ]
}

@test "vault_materialize: missing response key reports only the missing-key classification" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=fixture-foo-secret\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    [ "$output" = "vault: materialize failed, missing/empty keys: BAR_KEY" ]
    assert_output_not_contains "fixture-foo-secret"

    source "$VAULT_LIB"
    local cache leftovers
    cache="$(vault_secrets_file)"
    shopt -s nullglob
    leftovers=("${cache}".raw.* "${cache}".tmp.*)
    [ "${#leftovers[@]}" -eq 0 ]
    [ -f "${cache}.lock" ]
    [ ! -s "${cache}.lock" ]
}

@test "vault_materialize: unlisted response key gets its exact safe classification" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=fixture-foo-secret\nBAR_KEY=fixture-bar-secret\nEVIL_KEY=fixture-evil-secret\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    assert_output_contains "unlisted key"
    assert_output_not_contains "invalid KEY=VALUE syntax"
    assert_output_not_contains "duplicate key"
    assert_output_not_contains "fixture-foo-secret"
    assert_output_not_contains "fixture-bar-secret"
    assert_output_not_contains "fixture-evil-secret"

    source "$VAULT_LIB"
    [ ! -e "$(vault_secrets_file)" ]
}

@test "vault_materialize: duplicate response key gets its exact safe classification" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=fixture-first-secret\nBAR_KEY=fixture-bar-secret\nFOO_KEY=fixture-second-secret\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    assert_output_contains "duplicate key"
    assert_output_not_contains "invalid KEY=VALUE syntax"
    assert_output_not_contains "unlisted key"
    assert_output_not_contains "fixture-first-secret"
    assert_output_not_contains "fixture-second-secret"
    assert_output_not_contains "fixture-bar-secret"

    source "$VAULT_LIB"
    [ ! -e "$(vault_secrets_file)" ]
}

@test "vault_materialize: Bash 3.2 invalidates a changed-source cache before failing loudly" {
    _setup_materialize_fixture false
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\nBAR_KEY=bar\n'
EOF
    chmod +x "$MOCK_BIN/op"
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    printf '# vault-provider=onepassword\n# vault-source=op://Private/dotfiles\nFOO_KEY=stale\nBAR_KEY=stale\n' > "$cache"

    [ -x /bin/bash ] || skip "/bin/bash not present on this host"
    local sys_bash_major
    sys_bash_major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]:-0}"')"
    (( sys_bash_major < 4 )) || skip "/bin/bash is ${sys_bash_major}.x; this guard only trips on bash 3.2"

    run /bin/bash -c "source '$VAULT_LIB'; vault_materialize onepassword"
    [ "$status" -ne 0 ]
    [[ "$output" == *"requires bash >= 4"* ]]

    source "$VAULT_LIB"
    [ ! -e "$(vault_secrets_file)" ]
}

@test "vault_materialize: malformed response line gets its exact safe syntax classification" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=fixture-foo-secret\nfixture-continuation-secret\nBAR_KEY=fixture-bar-secret\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    assert_output_contains "invalid KEY=VALUE syntax"
    assert_output_not_contains "unlisted key"
    assert_output_not_contains "duplicate key"
    assert_output_not_contains "fixture-foo-secret"
    assert_output_not_contains "fixture-continuation-secret"
    assert_output_not_contains "fixture-bar-secret"
}

@test "vault_materialize: functrace preserves the caller RETURN trap and cleans its transaction" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=fixture-foo-secret\nBAR_KEY=fixture-bar-secret\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "
        set -euo pipefail
        set -o functrace
        source '$VAULT_LIB'
        caller_state=untouched
        trap 'caller_state=return-trap-fired' RETURN
        expected_trap=\"\$(trap -p RETURN)\"
        wrapper() {
            local local_state=caller-local
            DOTFILES_DIR='$DOTFILES_DIR' vault_materialize onepassword
            [[ \"\$local_state\" == caller-local ]]
            [[ \"\$(trap -p RETURN)\" == \"\$expected_trap\" ]]
        }
        wrapper
        [[ \"\$caller_state\" == return-trap-fired ]]
        [[ \"\$(trap -p RETURN)\" == \"\$expected_trap\" ]]
        printf 'caller-state=%s\n' \"\$caller_state\"
    "

    assert_success
    [ "$output" = "caller-state=return-trap-fired" ]

    source "$VAULT_LIB"
    local cache leftovers
    cache="$(vault_secrets_file)"
    [ "$(<"$cache")" = $'# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=fixture-foo-secret\nBAR_KEY=fixture-bar-secret' ]
    [ -f "${cache}.lock" ]
    [ ! -s "${cache}.lock" ]
    shopt -s nullglob
    leftovers=("${cache}".raw.* "${cache}".tmp.*)
    [ "${#leftovers[@]}" -eq 0 ]
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

@test "vault_materialize: empty response value reports only the missing-key classification" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=fixture-foo-secret\nBAR_KEY=\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -eq 1 ]
    [ "$output" = "vault: materialize failed, missing/empty keys: BAR_KEY" ]
    assert_output_not_contains "fixture-foo-secret"
}

@test "vault_materialize: same-source failure leaves the prior cache byte-identical" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
printf 'FOO_KEY=foo\n'
EOF
    chmod +x "$MOCK_BIN/op"

    source "$VAULT_LIB"
    local cache before
    cache="$(vault_secrets_file)"
    mkdir -p "$(dirname "$cache")"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Employee/dotfiles
FOO_KEY=old-foo
BAR_KEY=old-bar
EOF
    before="$TEST_HOME/cache-before"
    cp "$cache" "$before"

    run bash -c "source '$VAULT_LIB'; vault_materialize onepassword"

    [ "$status" -ne 0 ]
    cmp -s "$cache" "$before"
}

@test "vault_materialize: serialization failure preserves cache and never attempts rename" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
printf 'FOO_KEY=new-foo\nBAR_KEY=new-bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    source "$VAULT_LIB"
    local cache before
    cache="$(vault_secrets_file)"
    before="$TEST_HOME/cache-before"
    mkdir -p "$(dirname "$cache")"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Employee/dotfiles
FOO_KEY=old-foo
BAR_KEY=old-bar
EOF
    cp "$cache" "$before"

    export MKTEMP_CALL_COUNT="$TEST_HOME/mktemp-call-count"
    export MKTEMP_ROOT="$TEST_HOME/mktemp-results"
    export MV_CALLS="$TEST_HOME/mv-calls"
    mkdir -p "$MKTEMP_ROOT"
    : > "$MV_CALLS"
    cat > "$MOCK_BIN/mktemp" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f "$MKTEMP_CALL_COUNT" ]] || count="$(<"$MKTEMP_CALL_COUNT")"
((count += 1))
printf '%s\n' "$count" > "$MKTEMP_CALL_COUNT"
case "$count" in
    1)
        raw="$MKTEMP_ROOT/provider-response"
        : > "$raw"
        printf '%s\n' "$raw"
        ;;
    2)
        mkdir -p "$MKTEMP_ROOT/not-a-file"
        printf '%s\n' "$MKTEMP_ROOT/not-a-file"
        ;;
    *) exit 65 ;;
esac
EOF
    cat > "$MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$MV_CALLS"
exit 99
EOF
    chmod +x "$MOCK_BIN/mktemp" "$MOCK_BIN/mv"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    assert_failure
    [ "$(<"$MKTEMP_CALL_COUNT")" -eq 2 ]
    [ ! -s "$MV_CALLS" ]
    cmp -s "$cache" "$before"
    [ -f "${cache}.lock" ]
    [ ! -s "${cache}.lock" ]
}

@test "vault_materialize: failed atomic rename preserves the old cache and cleans temporary state" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
printf 'FOO_KEY=new-foo\nBAR_KEY=new-bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    source "$VAULT_LIB"
    local cache before leftovers
    cache="$(vault_secrets_file)"
    before="$TEST_HOME/cache-before"
    mkdir -p "$(dirname "$cache")"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Employee/dotfiles
FOO_KEY=old-foo
BAR_KEY=old-bar
EOF
    cp "$cache" "$before"
    export MV_CALLS="$TEST_HOME/mv-calls"
    : > "$MV_CALLS"
    cat > "$MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >> "$MV_CALLS"
exit 73
EOF
    chmod +x "$MOCK_BIN/mv"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    assert_failure
    [ "$(<"$MV_CALLS")" = called ]
    cmp -s "$cache" "$before"
    [ -f "${cache}.lock" ]
    [ ! -s "${cache}.lock" ]
    shopt -s nullglob
    leftovers=("${cache}".raw.* "${cache}".tmp.*)
    [ "${#leftovers[@]}" -eq 0 ]
}

@test "vault_materialize: successful atomic rename sees old bytes until commit" {
    _setup_materialize_fixture
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
printf 'FOO_KEY=new-foo\nBAR_KEY=new-bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    source "$VAULT_LIB"
    local cache before expected
    cache="$(vault_secrets_file)"
    before="$TEST_HOME/cache-before"
    mkdir -p "$(dirname "$cache")"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Employee/dotfiles
FOO_KEY=old-foo
BAR_KEY=old-bar
EOF
    cp "$cache" "$before"
    export CACHE_AT_MV="$TEST_HOME/cache-at-mv"
    export MV_CALLS="$TEST_HOME/mv-calls"
    export REAL_MV
    REAL_MV="$(command -v mv)"
    : > "$MV_CALLS"
    cat > "$MOCK_BIN/mv" <<'EOF'
#!/usr/bin/env bash
destination="${!#}"
[[ -f "$destination" ]] || exit 70
cp "$destination" "$CACHE_AT_MV" || exit 71
printf 'called\n' >> "$MV_CALLS"
exec "$REAL_MV" "$@"
EOF
    chmod +x "$MOCK_BIN/mv"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    assert_success
    [ "$(<"$MV_CALLS")" = called ]
    cmp -s "$CACHE_AT_MV" "$before"
    expected=$'# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=new-foo\nBAR_KEY=new-bar'
    [ "$(<"$cache")" = "$expected" ]
}

@test "vault_materialize: a terminated transaction recovers after its provider exits" {
    _setup_materialize_fixture
    source "$VAULT_LIB"
    local cache lock doomed_pid owner_pid doomed_status expected mode attempt
    cache="$(vault_secrets_file)"
    lock="${cache}.lock"
    export CONTROL="$TEST_HOME/dead-owner-control"
    mkdir -p "$CONTROL"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
printf '%s\n' "$PPID" > "$CONTROL/owner-pid"
: > "$CONTROL/provider-started"
while [[ ! -e "$CONTROL/stop-provider" ]]; do
    /bin/sleep 0.01
done
exit 1
EOF
    chmod +x "$MOCK_BIN/op"

    "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword" \
        > "$CONTROL/doomed-output" 2>&1 &
    doomed_pid=$!
    wait_for_vault_marker "$CONTROL/provider-started" "$doomed_pid"
    owner_pid="$(<"$CONTROL/owner-pid")"
    [[ "$owner_pid" =~ ^[0-9]+$ ]]
    kill -KILL "$owner_pid"
    : > "$CONTROL/stop-provider"
    if wait "$doomed_pid"; then
        doomed_status=0
    else
        doomed_status=$?
    fi
    [ "$doomed_status" -ne 0 ]
    [ -f "$lock" ]

    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
printf 'FOO_KEY=recovered-foo\nBAR_KEY=recovered-bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    for ((attempt = 0; attempt < 200; attempt += 1)); do
        run env _VAULT_LOCK_TIMEOUT=0 \
            "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"
        [[ "$status" -eq 0 ]] && break
        [ "$output" = "vault: timed out waiting for cache lock $lock; another vault transaction is still active." ]
        /bin/sleep 0.01
    done

    assert_success
    expected=$'# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=recovered-foo\nBAR_KEY=recovered-bar'
    [ "$(<"$cache")" = "$expected" ]
    [ -f "$lock" ]
    mode="$(stat -c '%a' "$lock" 2>/dev/null || stat -f '%Lp' "$lock")"
    [ "$mode" = 600 ]
    shopt -s nullglob
    local lock_artifacts=("${lock}.owner."* "${lock}.reaper"*)
    [ "${#lock_artifacts[@]}" -eq 0 ]
}

@test "vault_materialize: live lock timeout is bounded, actionable, and does not reap its owner" {
    _setup_materialize_fixture
    source "$VAULT_LIB"
    local cache lock owner_pid owner_status contender_status contender_output expected mode
    cache="$(vault_secrets_file)"
    lock="${cache}.lock"
    export CONTROL="$TEST_HOME/live-owner-control"
    export OP_CALLS="$CONTROL/op-calls"
    mkdir -p "$CONTROL"
    : > "$OP_CALLS"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
printf '%s\n' "${LOCK_ROLE:-contender}" >> "$OP_CALLS"
if [[ "${LOCK_ROLE:-}" == owner ]]; then
    : > "$CONTROL/owner-started"
    while [[ ! -e "$CONTROL/release-owner" ]]; do
        /bin/sleep 0.01
    done
fi
printf 'FOO_KEY=owner-foo\nBAR_KEY=owner-bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    LOCK_ROLE=owner "$BASH" -c \
        "source '$VAULT_LIB'; vault_materialize onepassword" \
        > "$CONTROL/owner-output" 2>&1 &
    owner_pid=$!
    wait_for_vault_marker "$CONTROL/owner-started" "$owner_pid"

    run env _VAULT_LOCK_TIMEOUT=0 \
        "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"
    contender_status="$status"
    contender_output="$output"
    : > "$CONTROL/release-owner"
    if wait "$owner_pid"; then
        owner_status=0
    else
        owner_status=$?
    fi

    [ "$contender_status" -eq 1 ]
    [[ "$contender_output" == *"$lock"* ]]
    [[ "$contender_output" == *"another vault transaction is still active"* ]]
    [ "$owner_status" -eq 0 ]
    [ "$(<"$OP_CALLS")" = owner ]
    expected=$'# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=owner-foo\nBAR_KEY=owner-bar'
    [ "$(<"$cache")" = "$expected" ]
    [ -f "$lock" ]
    mode="$(stat -c '%a' "$lock" 2>/dev/null || stat -f '%Lp' "$lock")"
    [ "$mode" = 600 ]
    shopt -s nullglob
    local lock_artifacts=("${lock}.owner."* "${lock}.reaper"*)
    [ "${#lock_artifacts[@]}" -eq 0 ]
}

@test "cache lock: kernel lock file remains mode 0600 without owner artifacts" {
    export DOTFILES_VAULT_PROVIDER=auto
    mock_unready_providers
    source "$VAULT_LIB"
    local cache lock mode
    cache="$(vault_secrets_file)"
    lock="${cache}.lock"

    run env _VAULT_LOCK_TIMEOUT=0 PATH="$MOCK_BIN:/usr/bin:/bin" \
        "$BASH" -c "source '$VAULT_LIB'; vault_resolve"

    assert_success
    [ "$output" = unconfigured ]
    [ -f "$lock" ]
    [ ! -s "$lock" ]
    mode="$(stat -c '%a' "$lock" 2>/dev/null || stat -f '%Lp' "$lock")"
    [ "$mode" = 600 ]
    shopt -s nullglob
    local lock_artifacts=("${lock}.owner."* "${lock}.reaper"*)
    [ "${#lock_artifacts[@]}" -eq 0 ]
}

@test "cache lock: lockf child re-sources a relatively sourced library after cwd changes" {
    local fixture elsewhere isolated_bin command
    fixture="$TEST_HOME/relative-vault"
    elsewhere="$TEST_HOME/elsewhere"
    isolated_bin="$TEST_HOME/lockf-bin"
    mkdir -p "$fixture" "$elsewhere" "$isolated_bin"
    cp "$VAULT_LIB" "$fixture/vault.sh"
    for command in mkdir chmod; do
        ln -s "$(command -v "$command")" "$isolated_bin/$command"
    done
    cat > "$isolated_bin/lockf" <<'EOF'
#!/bin/bash
[[ "$1" == -k && "$2" == -s && "$3" == -t ]] || exit 64
shift 4
lock=$1
shift
[[ -e "$lock" ]] || exit 65
"$@"
EOF
    chmod +x "$isolated_bin/lockf"

    run env PATH="$isolated_bin" VAULT_FIXTURE_DIR="$fixture" VAULT_OTHER_DIR="$elsewhere" \
        "$BASH" -c 'cd "$VAULT_FIXTURE_DIR"; source ./vault.sh; cd "$VAULT_OTHER_DIR"; vault_resolve'

    assert_success
    [ "$output" = unconfigured ]
}

@test "vault_materialize: wrong-source cache is absent when provider fetch begins" {
    _setup_materialize_fixture
    source "$VAULT_LIB"
    local cache
    cache="$(vault_secrets_file)"
    export CACHE_PATH="$cache"
    export CACHE_AT_FETCH="$TEST_HOME/cache-at-fetch"
    mkdir -p "$(dirname "$cache")"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Private/dotfiles
FOO_KEY=old-foo
BAR_KEY=old-bar
EOF
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
if [[ -e "$CACHE_PATH" ]]; then
    printf 'present\n' > "$CACHE_AT_FETCH"
else
    printf 'absent\n' > "$CACHE_AT_FETCH"
fi
exit 1
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    assert_failure
    [ "$(<"$CACHE_AT_FETCH")" = absent ]
    [ ! -e "$cache" ]
}

@test "vault_materialize: legacy cache is absent when provider fetch begins" {
    _setup_materialize_fixture
    source "$VAULT_LIB"
    local cache
    cache="$(vault_secrets_file)"
    export CACHE_PATH="$cache"
    export CACHE_AT_FETCH="$TEST_HOME/cache-at-fetch"
    mkdir -p "$(dirname "$cache")"
    printf 'FOO_KEY=old-foo\nBAR_KEY=old-bar\n' > "$cache"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
if [[ -e "$CACHE_PATH" ]]; then
    printf 'present\n' > "$CACHE_AT_FETCH"
else
    printf 'absent\n' > "$CACHE_AT_FETCH"
fi
exit 1
EOF
    chmod +x "$MOCK_BIN/op"

    run "$BASH" -c "source '$VAULT_LIB'; vault_materialize onepassword"

    assert_failure
    [ "$(<"$CACHE_AT_FETCH")" = absent ]
    [ ! -e "$cache" ]
}

@test "vault_materialize: derives 1Password refs and writes a tagged 0600 cache" {
    _setup_materialize_fixture
    export OP_INPUT="$TEST_HOME/op-input"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
cat > "$OP_INPUT"
printf 'FOO_KEY=foo\nBAR_KEY=bar\n'
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "source '$VAULT_LIB'; vault_materialize onepassword"
    [ "$status" -eq 0 ]

    local expected_input
    expected_input=$'FOO_KEY=op://Employee/dotfiles/FOO_KEY\nBAR_KEY=op://Employee/dotfiles/BAR_KEY'
    [ "$(<"$OP_INPUT")" = "$expected_input" ]

    source "$VAULT_LIB"
    local cache expected_cache mode
    cache="$(vault_secrets_file)"
    expected_cache=$'# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nFOO_KEY=foo\nBAR_KEY=bar'
    [ "$(<"$cache")" = "$expected_cache" ]
    if [[ "$(uname)" == Darwin ]]; then
        mode="$(stat -f %Lp "$cache")"
    else
        mode="$(stat -c %a "$cache")"
    fi
    [ "$mode" = 600 ]
}

@test "vault_materialize: committed manifest resolves all six 1Password fields" {
    _setup_materialize_fixture
    cp "$REAL_DOTFILES_DIR/secrets/secrets.env.tmpl" \
        "$DOTFILES_DIR/secrets/secrets.env.tmpl"
    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 1
while IFS='=' read -r key ref || [[ -n "$key$ref" ]]; do
    [[ "$ref" == "op://Employee/dotfiles/$key" ]] || exit 2
    printf '%s=value-%s\n' "$key" "$key"
done
EOF
    chmod +x "$MOCK_BIN/op"

    run bash -c "source '$VAULT_LIB'; vault_materialize onepassword"
    [ "$status" -eq 0 ]

    source "$VAULT_LIB"
    local cache expected
    cache="$(vault_secrets_file)"
    expected=$'# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nGH_TOKEN=value-GH_TOKEN\nGITHUB_PERSONAL_ACCESS_TOKEN=value-GITHUB_PERSONAL_ACCESS_TOKEN\nCONTEXT7_API_KEY=value-CONTEXT7_API_KEY\nTAVILY_API_KEY=value-TAVILY_API_KEY\nSERPER_API_KEY=value-SERPER_API_KEY\nTODOIST_API_KEY=value-TODOIST_API_KEY'
    [ "$(<"$cache")" = "$expected" ]
}

@test "vault_materialize: Bitwarden writes the same tagged six-key shape" {
    _setup_materialize_fixture
    cp "$REAL_DOTFILES_DIR/secrets/secrets.env.tmpl" \
        "$DOTFILES_DIR/secrets/secrets.env.tmpl"
    prepare_bitwarden_readiness
    export DOTFILES_VAULT_PROVIDER=bitwarden
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "secret list proj-1 -o env" ]] || exit 1
[[ "${BWS_ACCESS_TOKEN:-}" == "$BWS_FIXTURE_TOKEN" ]] || exit 2
while IFS='=' read -r key _ || [[ -n "$key" ]]; do
    printf '%s=value-%s\n' "$key" "$key"
done < "$DOTFILES_DIR/secrets/secrets.env.tmpl"
EOF
    chmod +x "$MOCK_BIN/bws"

    run bash -c "source '$VAULT_LIB'; vault_materialize bitwarden"
    [ "$status" -eq 0 ]

    source "$VAULT_LIB"
    local expected cache
    cache="$(vault_secrets_file)"
    expected=$'# vault-provider=bitwarden\n# vault-source=proj-1\nGH_TOKEN=value-GH_TOKEN\nGITHUB_PERSONAL_ACCESS_TOKEN=value-GITHUB_PERSONAL_ACCESS_TOKEN\nCONTEXT7_API_KEY=value-CONTEXT7_API_KEY\nTAVILY_API_KEY=value-TAVILY_API_KEY\nSERPER_API_KEY=value-SERPER_API_KEY\nTODOIST_API_KEY=value-TODOIST_API_KEY'
    [ "$(<"$cache")" = "$expected" ]
}

@test "vault_materialize: xtrace emits neither the Bitwarden token nor response values" {
    _setup_materialize_fixture
    prepare_bitwarden_readiness
    export DOTFILES_VAULT_PROVIDER=bitwarden
    cat > "$MOCK_BIN/bws" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "secret list proj-1 -o env" ]] || exit 1
[[ "${BWS_ACCESS_TOKEN:-}" == "$BWS_FIXTURE_TOKEN" ]] || exit 2
printf 'FOO_KEY=fixture-foo-secret\nBAR_KEY=fixture-bar-secret\n'
EOF
    chmod +x "$MOCK_BIN/bws"

    run "$BASH" -x -c "source '$VAULT_LIB'; vault_materialize bitwarden"

    assert_success
    assert_output_not_contains "$BWS_FIXTURE_TOKEN"
    assert_output_not_contains "fixture-foo-secret"
    assert_output_not_contains "fixture-bar-secret"

    source "$VAULT_LIB"
    local cache
    cache="$(vault_secrets_file)"
    [ "$(<"$cache")" = $'# vault-provider=bitwarden\n# vault-source=proj-1\nFOO_KEY=fixture-foo-secret\nBAR_KEY=fixture-bar-secret' ]
}

@test "vault_materialize: settings change during a locked fetch fails old request before the new source commits" {
    _setup_materialize_fixture
    unset DOTFILES_OP_ITEM DOTFILES_VAULT_PROVIDER
    export CONTROL="$TEST_HOME/materialize-control"
    mkdir -p "$CONTROL"
    cat > "$DOTFILES_DIR/.env" <<'EOF'
DOTFILES_VAULT_PROVIDER=onepassword
DOTFILES_OP_ITEM=op://Old/dotfiles
EOF
    source "$VAULT_LIB"
    local cache before old_pid new_pid old_status new_status expected
    local initial_cache_state fail_closed_state
    cache="$(vault_secrets_file)"
    before="$TEST_HOME/cache-before"
    mkdir -p "$(dirname "$cache")"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Old/dotfiles
FOO_KEY=old-cache-foo
BAR_KEY=old-cache-bar
EOF
    cp "$cache" "$before"

    cat > "$MOCK_BIN/op" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == inject ]] || exit 64
input="$(cat)"
case "$input" in
    *op://Old/dotfiles/*)
        : > "$CONTROL/old-fetch-started"
        while [[ ! -e "$CONTROL/release-old" ]]; do
            /bin/sleep 0.01
        done
        printf 'FOO_KEY=old-fetch-foo\nBAR_KEY=old-fetch-bar\n'
        ;;
    *op://New/dotfiles/*)
        : > "$CONTROL/new-fetch-started"
        while [[ ! -e "$CONTROL/release-new" ]]; do
            /bin/sleep 0.01
        done
        printf 'FOO_KEY=new-fetch-foo\nBAR_KEY=new-fetch-bar\n'
        ;;
    *) exit 65 ;;
esac
EOF
    chmod +x "$MOCK_BIN/op"

    "$BASH" -c \
        "source '$VAULT_LIB'; vault_materialize onepassword" \
        > "$CONTROL/old-output" 2>&1 &
    old_pid=$!
    wait_for_vault_marker "$CONTROL/old-fetch-started" "$old_pid"

    cat > "$DOTFILES_DIR/.env" <<'EOF'
DOTFILES_VAULT_PROVIDER=onepassword
DOTFILES_OP_ITEM=op://New/dotfiles
EOF
    "$BASH" -c \
        'source "$1"; : > "$CONTROL/new-contended"; vault_materialize onepassword' \
        vault-new "$VAULT_LIB" > "$CONTROL/new-output" 2>&1 &
    new_pid=$!
    wait_for_vault_marker "$CONTROL/new-contended" "$new_pid"
    kill -0 "$new_pid"
    [ ! -e "$CONTROL/new-fetch-started" ]
    if cmp -s "$cache" "$before"; then
        initial_cache_state=unchanged
    else
        initial_cache_state=changed
    fi

    : > "$CONTROL/release-old"
    wait_for_vault_marker "$CONTROL/new-fetch-started" "$new_pid"
    if wait "$old_pid"; then
        old_status=0
    else
        old_status=$?
    fi
    if [[ -e "$cache" ]]; then
        fail_closed_state=present
    else
        fail_closed_state=absent
    fi

    : > "$CONTROL/release-new"
    if wait "$new_pid"; then
        new_status=0
    else
        new_status=$?
    fi
    [ "$initial_cache_state" = unchanged ]
    [ "$old_status" -eq 1 ]
    [ "$fail_closed_state" = absent ]
    [ "$new_status" -eq 0 ]

    expected=$'# vault-provider=onepassword\n# vault-source=op://New/dotfiles\nFOO_KEY=new-fetch-foo\nBAR_KEY=new-fetch-bar'
    [ "$(<"$cache")" = "$expected" ]
}

@test "vault_materialize: rejects non-concrete provider arguments" {
    _setup_materialize_fixture

    run bash -c "source '$VAULT_LIB'; vault_materialize auto"

    [ "$status" -ne 0 ]
    [[ "$output" == *"onepassword or bitwarden"* ]]
}

# ── loader parity ──

@test "loader parity: bin/lib/vault.sh's own cache path resolves a cache-only key" {
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    mkdir -p "$XDG_CACHE_HOME/dotfiles"
    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nCACHE_ONLY_KEY=vlib\n' > "$XDG_CACHE_HOME/dotfiles/secrets.env"

    source "$VAULT_LIB"
    run cat "$(vault_secrets_file)"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CACHE_ONLY_KEY=vlib"* ]]
}

@test "loader parity: zsh/core.zsh sources a cache-only key" {
    command -v zsh &>/dev/null || skip "zsh not installed"
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    mkdir -p "$XDG_CACHE_HOME/dotfiles"
    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nCACHE_ONLY_KEY=zsh\n' > "$XDG_CACHE_HOME/dotfiles/secrets.env"

    run zsh -fc "export DOTFILES_DIR='$REAL_DOTFILES_DIR' XDG_CACHE_HOME='$XDG_CACHE_HOME' HOME='$TEST_HOME'; source '$REAL_DOTFILES_DIR/zsh/core.zsh'; printf '%s' \"\$CACHE_ONLY_KEY\""
    [ "$status" -eq 0 ]
    [ "$output" = "zsh" ]
}

@test "loader parity: bin/cc-env-exec exports a cache-only key" {
    export XDG_CACHE_HOME="$TEST_HOME/.cache"
    mkdir -p "$XDG_CACHE_HOME/dotfiles"
    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nCACHE_ONLY_KEY=ccenv\n' > "$XDG_CACHE_HOME/dotfiles/secrets.env"
    export DOTFILES_DIR="$REAL_DOTFILES_DIR"

    run "$REAL_DOTFILES_DIR/bin/cc-env-exec" sh -c 'printf %s "$CACHE_ONLY_KEY"'
    [ "$status" -eq 0 ]
    [ "$output" = "ccenv" ]
}

@test "loader parity: MCP dotenv loader ignores cache provenance" {
    local cache="$TEST_HOME/secrets.env"
    printf '# vault-provider=onepassword\n# vault-source=op://Employee/dotfiles\nCACHE_ONLY_KEY=mcp\n' > "$cache"

    run bash -c "source '$REAL_DOTFILES_DIR/agents/mcp/lib.sh'; mcp_load_dotenv '$cache'; printf '%s' \"\$CACHE_ONLY_KEY\""

    [ "$status" -eq 0 ]
    [ "$output" = "mcp" ]
}


# ── headless-Linux token storage ──
#
# _vault_token branches on `uname -s`; these mock uname to exercise the Linux
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

@test "_vault_token: on Linux reads the 0600 token file" {
    mock_linux_uname
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf 'tok-abc123\n' > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 600 "$XDG_CONFIG_HOME/dotfiles/bws-token"

    source "$VAULT_LIB"
    run _vault_token
    [ "$status" -eq 0 ]
    [ "$output" = "tok-abc123" ]
}

@test "_vault_token: on Linux rejects an empty 0600 token file" {
    mock_linux_uname
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    : > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 600 "$XDG_CONFIG_HOME/dotfiles/bws-token"

    source "$VAULT_LIB"
    run _vault_token

    assert_failure
    assert_output_contains "empty"
}

@test "_vault_token: on Linux refuses a group/world-readable token file" {
    mock_linux_uname
    export XDG_CONFIG_HOME="$TEST_HOME/.config"
    mkdir -p "$XDG_CONFIG_HOME/dotfiles"
    printf 'tok-abc123\n' > "$XDG_CONFIG_HOME/dotfiles/bws-token"
    chmod 644 "$XDG_CONFIG_HOME/dotfiles/bws-token"

    source "$VAULT_LIB"
    run _vault_token
    [ "$status" -ne 0 ]
    [[ "$output" == *"must be mode 600"* ]]
    # the secret itself must never be echoed on the refusal path
    [[ "$output" != *"tok-abc123"* ]]
}

@test "_vault_token: on Linux a missing token file names bin/vault-provision" {
    mock_linux_uname
    export XDG_CONFIG_HOME="$TEST_HOME/.config"

    source "$VAULT_LIB"
    run _vault_token
    [ "$status" -ne 0 ]
    [[ "$output" == *"bin/vault-provision"* ]]
}
# ── sync bootstrap states ──

@test "_vault_project_id: reads BWS_PROJECT_ID from the machine-local settings file" {
    printf 'DOTFILES_DEV=false\nBWS_PROJECT_ID=proj-from-file\n' > "$DOTFILES_DIR/.env"

    source "$VAULT_LIB"
    run _vault_project_id

    [ "$status" -eq 0 ]
    [ "$output" = "proj-from-file" ]
}

@test "materialize_secrets: auto with no ready provider and no cache is a non-failing bootstrap state" {
    export DOTFILES_VAULT_PROVIDER=auto
    mock_unready_providers

    run env PATH="$MOCK_BIN:/usr/bin:/bin" bash -c "
        set -euo pipefail
        dir='$REAL_DOTFILES_DIR'
        source '$VAULT_LIB'
        source '$REAL_DOTFILES_DIR/.sync-lib.sh'
        SYNC_FAILURES=()
        materialize_secrets
        printf 'SYNC_FAILURES=%s' \"\${#SYNC_FAILURES[@]}\"
    "

    [ "$status" -eq 0 ]
    [[ "$output" == *"SYNC_FAILURES=0"* ]]
}

@test "materialize_secrets: auto with no ready provider records failure and preserves tagged cache" {
    export DOTFILES_VAULT_PROVIDER=auto
    export DOTFILES_OP_ITEM=op://Employee/dotfiles
    mock_unready_providers
    local cache="$HOME/.cache/dotfiles/secrets.env"
    mkdir -p "${cache%/*}"
    cat > "$cache" <<'EOF'
# vault-provider=onepassword
# vault-source=op://Employee/dotfiles
FOO_KEY=old
BAR_KEY=old
EOF
    local before="$TEST_HOME/cache-before"
    cp "$cache" "$before"

    run env PATH="$MOCK_BIN:/usr/bin:/bin" bash -c "
        set -euo pipefail
        dir='$REAL_DOTFILES_DIR'
        source '$VAULT_LIB'
        source '$REAL_DOTFILES_DIR/.sync-lib.sh'
        SYNC_FAILURES=()
        materialize_secrets
        printf 'SYNC_FAILURES=%s' \"\${#SYNC_FAILURES[@]}\"
    "

    [ "$status" -eq 0 ]
    [[ "$output" == *"SYNC_FAILURES=1"* ]]
    cmp -s "$cache" "$before"
}
