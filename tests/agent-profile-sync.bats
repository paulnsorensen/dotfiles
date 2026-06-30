#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317

load test_helper

setup() {
    setup_test_env
    LIB="$REAL_DOTFILES_DIR/chezmoi/lib/agent-profile-sync.sh"
    FAKE_BIN="$TEST_HOME/fake-bin"
    mkdir -p "$FAKE_BIN"

    export AGENT_PROFILE_CACHE_DIR="$TEST_HOME/cache/live"
    export TMPDIR="$TEST_HOME/tmp"
    mkdir -p "$TMPDIR"

    export AP_LOG="$TEST_HOME/ap-calls.log"
    export CHEZMOI_LOG="$TEST_HOME/chezmoi-calls.log"
    export MOCK_AP_DRIFT=0
    : >"$AP_LOG"
    : >"$CHEZMOI_LOG"

    cat >"$FAKE_BIN/ap" <<'SH'
#!/usr/bin/env bash
echo "ap $*" >>"$AP_LOG"
cmd=$1
shift
case "$cmd" in
    fetch-sources)
        exit 0
        ;;
    compile)
        out=""
        while (($#)); do
            case "$1" in
                --out) out=$2; shift 2 ;;
                --out=*) out=${1#--out=}; shift ;;
                --baseline) shift 2 ;;
                --baseline=*) shift ;;
                *) shift ;;
            esac
        done
        mkdir -p "$out"
        if [[ ${MOCK_AP_DRIFT:-0} == 1 ]]; then
            echo "DRIFT: home .claude/settings.json model changed"
            printf '%s\n' '{"profile":"live","drift":[{"target":"home","relative_path":".claude/settings.json","path":"model"}]}' >"$out/manifest.json"
        else
            printf '%s\n' '{"profile":"live","drift":[]}' >"$out/manifest.json"
        fi
        exit 0
        ;;
    apply-compiled)
        exit 0
        ;;
    *)
        echo "ap: unknown subcommand '$cmd'" >&2
        exit 99
        ;;
esac
SH
    chmod +x "$FAKE_BIN/ap"

    cat >"$FAKE_BIN/chezmoi" <<'SH'
#!/usr/bin/env bash
echo "chezmoi $*" >>"$CHEZMOI_LOG"
dest=""
while (($#)); do
    case "$1" in
        --destination) dest=$2; shift 2 ;;
        --destination=*) dest=${1#--destination=}; shift ;;
        *) shift ;;
    esac
done
[[ -n "$dest" ]] && mkdir -p "$dest"
exit 0
SH
    chmod +x "$FAKE_BIN/chezmoi"
    export PATH="$FAKE_BIN:$PATH"
}

teardown() { teardown_test_env; }

_force_noninteractive() { _apsync_interactive() { return 1; }; }
_force_interactive_no() {
    _apsync_interactive() { return 0; }
    _apsync_confirm() { return 1; }
}
_force_interactive_yes() {
    _apsync_interactive() { return 0; }
    _apsync_confirm() { return 0; }
}

@test "agent-profile-sync.sh sources with no output and no external calls" {
    run bash -c "source '$LIB'"
    assert_success
    [[ -z "$output" ]]
    run cat "$AP_LOG"
    [[ -z "$output" ]]
}

@test "sourcing does not leak set -e into the caller" {
    run bash -c "source '$LIB'; false; echo SURVIVED"
    assert_success
    assert_output_contains "SURVIVED"
}

@test "sourcing defines the public entrypoint" {
    run bash -c "source '$LIB'; declare -F agent_profile_sync >/dev/null && echo DEFINED"
    assert_success
    assert_output_contains "DEFINED"
}

@test "noninteractive drift without override fails before apply" {
    MOCK_AP_DRIFT=1
    source "$LIB"
    _force_noninteractive

    run agent_profile_sync live

    assert_failure
    assert_output_contains "--accept-agent-drift"
    grep -qF "compile live" "$AP_LOG"
    ! grep -qF "apply-compiled" "$AP_LOG"
}

@test "noninteractive drift with override shows drift and applies" {
    MOCK_AP_DRIFT=1
    source "$LIB"
    _force_noninteractive

    run agent_profile_sync live --accept-agent-drift

    assert_success
    assert_output_contains "DRIFT:"
    assert_output_contains "--accept-agent-drift"
    grep -qF "apply-compiled" "$AP_LOG"
}

@test "interactive drift default No aborts before apply" {
    MOCK_AP_DRIFT=1
    source "$LIB"
    _force_interactive_no

    run agent_profile_sync live

    assert_failure
    ! grep -qF "apply-compiled" "$AP_LOG"
}

@test "interactive drift Yes applies" {
    MOCK_AP_DRIFT=1
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live

    assert_success
    grep -qF "apply-compiled" "$AP_LOG"
}

@test "no drift applies without prompting" {
    source "$LIB"
    _apsync_interactive() { return 0; }
    _apsync_confirm() { echo PROMPTED; return 1; }

    run agent_profile_sync live

    assert_success
    assert_output_not_contains "PROMPTED"
    grep -qF "apply-compiled" "$AP_LOG"
}

@test "happy path renders baseline, fetches sources, compiles, then applies" {
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live

    assert_success
    grep -qF "apply" "$CHEZMOI_LOG"
    grep -qF "fetch-sources live" "$AP_LOG"
    grep -qF "compile live --baseline" "$AP_LOG"
    grep -qF "apply-compiled" "$AP_LOG"
}

@test "chezmoi baseline render failure aborts before ap calls" {
    cat >"$FAKE_BIN/chezmoi" <<'SH'
#!/usr/bin/env bash
echo "chezmoi $*" >>"$CHEZMOI_LOG"
exit 3
SH
    chmod +x "$FAKE_BIN/chezmoi"
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live

    assert_failure
    assert_output_contains "baseline"
    ! grep -qF "ap " "$AP_LOG"
}

@test "ap fetch-sources failure aborts before compile and apply" {
    cat >"$FAKE_BIN/ap" <<'SH'
#!/usr/bin/env bash
echo "ap $*" >>"$AP_LOG"
[[ $1 == fetch-sources ]] && exit 4
exit 0
SH
    chmod +x "$FAKE_BIN/ap"
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live

    assert_failure
    grep -qF "fetch-sources" "$AP_LOG"
    ! grep -qF "compile" "$AP_LOG"
    ! grep -qF "apply-compiled" "$AP_LOG"
}

@test "ap compile failure aborts before apply" {
    cat >"$FAKE_BIN/ap" <<'SH'
#!/usr/bin/env bash
echo "ap $*" >>"$AP_LOG"
[[ $1 == compile ]] && exit 5
exit 0
SH
    chmod +x "$FAKE_BIN/ap"
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live

    assert_failure
    ! grep -qF "apply-compiled" "$AP_LOG"
}

@test "ap apply-compiled failure is a sync failure" {
    cat >"$FAKE_BIN/ap" <<'SH'
#!/usr/bin/env bash
echo "ap $*" >>"$AP_LOG"
case "$1" in
    compile)
        out=""
        while (($#)); do
            case "$1" in
                --out) out=$2; shift 2 ;;
                --out=*) out=${1#--out=}; shift ;;
                *) shift ;;
            esac
        done
        mkdir -p "$out"
        printf '%s\n' '{"drift":[]}' >"$out/manifest.json"
        exit 0
        ;;
    apply-compiled)
        exit 6
        ;;
    *)
        exit 0
        ;;
esac
SH
    chmod +x "$FAKE_BIN/ap"
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live

    assert_failure
}

@test "missing ap binary reports a clear error" {
    source "$LIB"
    _force_interactive_yes

    AGENT_PROFILE_AP="$TEST_HOME/no-such-ap" run agent_profile_sync live

    assert_failure
    assert_output_contains "ap"
}

@test "agent_profile_sync requires a profile argument" {
    source "$LIB"

    run agent_profile_sync

    assert_failure
    assert_output_contains "Usage:"
}

@test "agent_profile_sync rejects an unknown option" {
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live --bogus

    assert_failure
}

@test "agent_profile_has_drift succeeds for a non-empty drift array" {
    source "$LIB"
    mkdir -p "$AGENT_PROFILE_CACHE_DIR"
    printf '%s\n' '{"drift":[{"file":"x"}]}' >"$AGENT_PROFILE_CACHE_DIR/manifest.json"

    run agent_profile_has_drift "$AGENT_PROFILE_CACHE_DIR"

    assert_success
}

@test "agent_profile_has_drift fails for empty or absent drift" {
    source "$LIB"
    mkdir -p "$AGENT_PROFILE_CACHE_DIR"
    printf '%s\n' '{"profile":"live"}' >"$AGENT_PROFILE_CACHE_DIR/manifest.json"

    run agent_profile_has_drift "$AGENT_PROFILE_CACHE_DIR"

    assert_failure
}

@test "drift gate fails closed when manifest is unreadable" {
    source "$LIB"
    _force_interactive_yes
    mkdir -p "$AGENT_PROFILE_CACHE_DIR"
    printf '%s\n' 'not-json{' >"$AGENT_PROFILE_CACHE_DIR/manifest.json"

    run agent_profile_drift_gate "$AGENT_PROFILE_CACHE_DIR" false

    assert_failure
}

@test "scratch baseline dir is cleaned up after successful sync" {
    source "$LIB"
    _force_interactive_yes

    run agent_profile_sync live

    assert_success
    run bash -c "find '$TMPDIR' -maxdepth 1 -type d -name 'ap-baseline-*' | wc -l"
    [[ "$(echo "$output" | tr -d ' ')" == 0 ]]
}
