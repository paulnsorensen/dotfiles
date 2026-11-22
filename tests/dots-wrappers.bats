#!/usr/bin/env bats
# The bin/dots* wrappers replace each harness's native system prompt with
# the tilth preamble joined with agents/preamble.md. T3 Code launches them
# through providerInstances
# binaryPath (chezmoi/.chezmoidata/t3.yaml). A fake harness binary prints its
# argv and the OpenCode config variable, so each test checks the launch line.

load test_helper
bats_require_minimum_version 1.5.0

setup() {
    setup_test_env
    export AGENTS_DOTFILES="$TEST_HOME/agents"
    mkdir -p "$AGENTS_DOTFILES" "$TEST_HOME/fakebin"
    printf '# Execution preamble\n' > "$AGENTS_DOTFILES/preamble.md"
    cat > "$TEST_HOME/fakebin/harness" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
printf 'CONFIG=%s\n' "${OPENCODE_CONFIG_CONTENT-<unset>}"
SH
    chmod +x "$TEST_HOME/fakebin/harness"
    export CLAUDE_BIN="$TEST_HOME/fakebin/harness"
    export CODEX_BIN="$TEST_HOME/fakebin/harness"
    export OPENCODE_BIN="$TEST_HOME/fakebin/harness"
    # No cc-env-exec here, so dotsclaude execs the harness directly.
    export DOTFILES_DIR="$TEST_HOME/no-dotfiles"
    unset OPENCODE_CONFIG_CONTENT
    # A failing tilth keeps the suite hermetic: the wrappers then pass the
    # dotfiles preamble alone. The joined-preamble tests replace this stub.
    export PATH="$TEST_HOME/fakebin:$PATH"
    stub_tilth fail
}

teardown() { teardown_test_env; }

# stub_tilth_text <text> — put a fake tilth first on PATH. Its
# `preamble --path` call prints the path of a file that holds <text>. Every
# other call exits 2, as an unknown argument does.
stub_tilth_text() {
    printf '%s' "$1" > "$TEST_HOME/tilth-preamble.md"
    cat > "$TEST_HOME/fakebin/tilth" <<SH
#!/bin/sh
[ "\$1" = preamble ] && [ "\$2" = --path ] || exit 2
printf '%s\n' '$TEST_HOME/tilth-preamble.md'
SH
    chmod +x "$TEST_HOME/fakebin/tilth"
}

# stub_tilth <mode> — put a fake tilth first on PATH.
#   preamble : a tilth with `preamble --path`
#   old      : a tilth without the subcommand; it rejects `--path`
#   fail     : a tilth that exits 1
stub_tilth() {
    case "$1" in
        preamble) stub_tilth_text $'# tilth agent preamble\n\nbase rule\n' ;;
        old)      printf '%s\n' '#!/bin/sh' 'echo "error: unexpected argument --path" >&2' 'exit 2' > "$TEST_HOME/fakebin/tilth" ;;
        fail)     printf '%s\n' '#!/bin/sh' 'exit 1' > "$TEST_HOME/fakebin/tilth" ;;
    esac
    chmod +x "$TEST_HOME/fakebin/tilth"
}

config_of() { sed -n 's/^CONFIG=//p' <<<"$1"; }

@test "dotsclaude replaces the system prompt with the preamble" {
    run "$REAL_DOTFILES_DIR/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$AGENTS_DOTFILES/preamble.md" ]
    [ "${lines[2]}" = "-p" ]
    [ "${lines[3]}" = "hi" ]
}

@test "dotscodex sets model_instructions_file before the subcommand" {
    run "$REAL_DOTFILES_DIR/bin/dotscodex" app-server --listen stdio
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-c" ]
    [ "${lines[1]}" = "model_instructions_file=\"$AGENTS_DOTFILES/preamble.md\"" ]
    [ "${lines[2]}" = "app-server" ]
    [ "${lines[3]}" = "--listen" ]
    [ "${lines[4]}" = "stdio" ]
}

@test "dotscodex escapes the preamble path as a TOML string" {
    export AGENTS_DOTFILES="$TEST_HOME"'/odd "dir"\x'
    mkdir -p "$AGENTS_DOTFILES"
    printf 'p\n' > "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = 'model_instructions_file="'"$TEST_HOME"'/odd \"dir\"\\x/preamble.md"' ]
}

@test "dotscodex passes arguments through when the preamble is missing" {
    rm "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotscodex" exec hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "exec" ]
    [ "${lines[1]}" = "hi" ]
}

@test "dotsopencode prompts match the opencode registry" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    command -v yq >/dev/null 2>&1 || skip "yq not installed"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "serve" ]
    local config registry
    config=$(config_of "$output")
    registry=$(yq -o=json '.opencode.config.agent' "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/opencode.yaml" \
        | jq -c '{build, plan, general, explore} | map_values({prompt})')
    jq -e --argjson want "$registry" '.agent == $want' <<<"$config"
}

@test "dotsopencode uses the installed preamble path that the global config lists" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    mkdir -p "$HOME/.config/opencode"
    printf 'p\n' > "$HOME/.config/opencode/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e '.instructions == ["~/.config/opencode/preamble.md"]' <<<"$(config_of "$output")"
    run yq -o=json '.opencode.config.instructions' "$REAL_DOTFILES_DIR/chezmoi/.chezmoidata/opencode.yaml"
    jq -e '. == ["~/.config/opencode/preamble.md"]' <<<"$output"
}

@test "dotsopencode falls back to the clone preamble" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$AGENTS_DOTFILES/preamble.md" '.instructions == [$p]' <<<"$(config_of "$output")"
}

@test "dotsopencode merges into the caller config and lets caller keys win" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export OPENCODE_CONFIG_CONTENT='{"share":"disabled","agent":{"build":{"prompt":"caller"}}}'
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e '.share == "disabled" and .agent.build.prompt == "caller" and (.agent.plan.prompt | contains("Plan only."))' \
        <<<"$(config_of "$output")"
}

@test "dotsopencode keeps the preamble when the caller config has instructions" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    local p="$AGENTS_DOTFILES/preamble.md"
    OPENCODE_CONFIG_CONTENT=$(jq -cn --arg p "$p" '{instructions: ["extra.md", $p, "extra.md"]}')
    export OPENCODE_CONFIG_CONTENT
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$p" '.instructions == [$p, "extra.md"]' <<<"$(config_of "$output")"
}

@test "dotsopencode leaves the config unchanged when jq is missing" {
    local nojq="$TEST_HOME/nojq"
    mkdir -p "$nojq"
    ln -s "$(command -v bash)" "$nojq/bash"
    ln -s "$(command -v dirname)" "$nojq/dirname"
    export OPENCODE_CONFIG_CONTENT='{"share":"disabled"}'
    # env is an absolute path, so only the wrapper sees the jq-free PATH.
    run --separate-stderr /usr/bin/env PATH="$nojq" "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "serve" ]
    [ "$(config_of "$output")" = '{"share":"disabled"}' ]
    [[ "$stderr" == *"jq missing"* ]]
}

@test "wrappers find the preamble in a clone outside ~/Dev" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    local clone="$TEST_HOME/code/my dots"
    mkdir -p "$clone/bin/lib" "$clone/agents"
    # The wrappers resolve their clone with `cd -P`; macOS TMPDIR sits behind
    # the /var -> /private/var symlink, so compare against the physical path.
    clone="$(cd -P "$clone" && pwd)"
    cp "$REAL_DOTFILES_DIR"/bin/dots{claude,codex,opencode} "$clone/bin/"
    cp "$REAL_DOTFILES_DIR/bin/lib/preamble-wrappers.sh" "$clone/bin/lib/"
    printf 'p\n' > "$clone/agents/preamble.md"
    unset AGENTS_DOTFILES DOTFILES_DIR
    run "$clone/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "$clone/agents/preamble.md" ]
    run "$clone/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "model_instructions_file=\"$clone/agents/preamble.md\"" ]
    run "$clone/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$clone/agents/preamble.md" '.instructions == [$p]' <<<"$(config_of "$output")"
}

@test "dotsclaude passes the real clone to cc-env-exec through a symlinked bin" {
    local clone="$TEST_HOME/code/my dots"
    mkdir -p "$clone/bin/lib" "$clone/agents"
    cp "$REAL_DOTFILES_DIR/bin/dotsclaude" "$clone/bin/"
    cp "$REAL_DOTFILES_DIR/bin/lib/preamble-wrappers.sh" "$clone/bin/lib/"
    cat > "$clone/bin/cc-env-exec" <<'SH'
#!/bin/sh
printf 'DOTFILES_DIR=%s\n' "$DOTFILES_DIR"
SH
    chmod +x "$clone/bin/cc-env-exec"
    printf 'p\n' > "$clone/agents/preamble.md"
    ln -s "$clone/bin" "$TEST_HOME/linkbin"
    local real
    real=$(cd -P "$clone" && pwd)
    unset AGENTS_DOTFILES DOTFILES_DIR
    run "$TEST_HOME/linkbin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "$output" = "DOTFILES_DIR=$real" ]
}

@test "preamble library functions keep the caller shell usable under strict mode" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    run bash -c '
        set -euo pipefail
        source "$1/bin/lib/preamble-wrappers.sh"
        home=$2
        caller() {
            dots_codex_instructions_override "$home/missing.md" || echo "codex:none"
            dots_opencode_preamble_path "$home/nowhere" || echo "opencode:none"
            dots_opencode_config p "[1]" || echo "config:rejected"
            dots_opencode_config p "" | jq -r ".instructions[0]"
        }
        caller
        echo after
    ' _ "$REAL_DOTFILES_DIR" "$TEST_HOME"
    [ "$status" -eq 0 ]
    [ "$output" = $'codex:none\nopencode:none\nconfig:rejected\np\nafter' ]
}

@test "dotsopencode leaves a malformed caller config unchanged" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    export OPENCODE_CONFIG_CONTENT='[1,2]'
    run --separate-stderr "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "$(config_of "$output")" = '[1,2]' ]
    [[ "$stderr" == *"not a JSON object"* ]]
}

@test "dotsopencode passes through when no preamble exists" {
    rm "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    [ "$(config_of "$output")" = "<unset>" ]
}

# ── the tilth preamble as the base ───────────────────────────────────────────

@test "dots-preamble joins the tilth preamble and the dotfiles preamble" {
    stub_tilth preamble
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [[ "$output" == "$HOME/.cache/dotfiles/preamble-"*.md ]]
    [ "$(cat "$output")" = $'# tilth agent preamble\n\nbase rule\n\n# Execution preamble' ]
}

@test "dots-preamble gives one path per content and a new path for new content" {
    stub_tilth preamble
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    local first="$output"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$output" = "$first" ]
    printf 'changed\n' >> "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" != "$first" ]
    [ "$(tail -n 1 "$output")" = "changed" ]
    # The first file stays, so a running session keeps its prompt file.
    [ -f "$first" ]
}

@test "dots-preamble falls back to the dotfiles preamble without a usable tilth" {
    local mode
    for mode in fail old; do
        stub_tilth "$mode"
        run "$REAL_DOTFILES_DIR/bin/dots-preamble"
        [ "$status" -eq 0 ]
        [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    done
    # No tilth on PATH at all.
    rm "$TEST_HOME/fakebin/tilth"
    run /usr/bin/env PATH="$TEST_HOME/fakebin:/usr/bin:/bin" "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    [ ! -e "$HOME/.cache/dotfiles" ]
}

@test "dots-preamble falls back silently when the cache directory is not writable" {
    stub_tilth preamble
    printf 'x\n' > "$TEST_HOME/not-a-dir"
    XDG_CACHE_HOME="$TEST_HOME/not-a-dir" run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
}

@test "dots-preamble fails when the dotfiles preamble is missing" {
    stub_tilth preamble
    rm "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "dotsclaude and dotscodex pass the joined preamble" {
    stub_tilth preamble
    local joined
    joined=$("$REAL_DOTFILES_DIR/bin/dots-preamble")
    [[ "$joined" == "$HOME/.cache/dotfiles/preamble-"*.md ]]
    run "$REAL_DOTFILES_DIR/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$joined" ]
    [ "${lines[2]}" = "-p" ]
    run "$REAL_DOTFILES_DIR/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-c" ]
    [ "${lines[1]}" = "model_instructions_file=\"$joined\"" ]
    [ "${lines[2]}" = "exec" ]
}

@test "dotsopencode passes the joined preamble when no installed copy exists" {
    command -v jq >/dev/null 2>&1 || skip "jq not installed"
    stub_tilth preamble
    local joined
    joined=$("$REAL_DOTFILES_DIR/bin/dots-preamble")
    [[ "$joined" == "$HOME/.cache/dotfiles/preamble-"*.md ]]
    run "$REAL_DOTFILES_DIR/bin/dotsopencode" serve
    [ "$status" -eq 0 ]
    jq -e --arg p "$joined" '.instructions == [$p]' <<<"$(config_of "$output")"
}

@test "the real tilth preamble comes first and the dotfiles preamble is the tail" {
    rm "$TEST_HOME/fakebin/tilth"
    [[ "$(tilth preamble 2>/dev/null)" == "# tilth agent preamble"* ]] \
        || skip "a tilth with the preamble subcommand is not installed"
    local real="$REAL_DOTFILES_DIR/agents/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble" "$real"
    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$output")" = "# tilth agent preamble" ]
    diff <(tail -n "$(wc -l < "$real")" "$output") "$real"
}

@test "dots_effective_preamble keeps the caller shell usable under strict mode" {
    stub_tilth fail
    run bash -c '
        set -euo pipefail
        source "$1/bin/lib/preamble-wrappers.sh"
        dots_effective_preamble "$2/missing.md" || echo "preamble:none"
        dots_effective_preamble "$2/agents/preamble.md"
        echo after
    ' _ "$REAL_DOTFILES_DIR" "$TEST_HOME"
    [ "$status" -eq 0 ]
    [ "$output" = $'preamble:none\n'"$AGENTS_DOTFILES"$'/preamble.md\nafter' ]
}

@test "dots-preamble ignores a relative XDG_CACHE_HOME" {
    stub_tilth preamble
    XDG_CACHE_HOME="relative/cache" run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [[ "$output" == "$HOME/.cache/dotfiles/preamble-"*.md ]]
}

# ── adversarial cases for the joined preamble ────────────────────────────────

@test "dotscodex escapes quotes and backslashes in the joined preamble path" {
    stub_tilth preamble
    local odd="$TEST_HOME/odd \"dir\"\\x" want
    XDG_CACHE_HOME="$odd" run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    local joined="$output"
    [[ "$joined" == "$odd/dotfiles/preamble-"*.md ]]
    [ -f "$joined" ]
    want="model_instructions_file=\"$(printf '%s' "$joined" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    XDG_CACHE_HOME="$odd" run "$REAL_DOTFILES_DIR/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-c" ]
    [ "${lines[1]}" = "$want" ]
    [ "${lines[2]}" = "exec" ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "dotscodex escapes a dotfiles preamble path with quotes and spaces" {
    local odd="$TEST_HOME/agents \"x\"\\y" want
    mkdir -p "$odd"
    printf '# Odd\n' > "$odd/preamble.md"
    want="model_instructions_file=\"$(printf '%s' "$odd/preamble.md" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
    AGENTS_DOTFILES="$odd" run "$REAL_DOTFILES_DIR/bin/dotscodex" exec
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-c" ]
    [ "${lines[1]}" = "$want" ]
}

@test "dots-preamble falls back when tilth prints the heading and then fails" {
    stub_tilth preamble
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' '$TEST_HOME/tilth-preamble.md'" 'exit 3' > "$TEST_HOME/fakebin/tilth"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    [ ! -e "$HOME/.cache/dotfiles" ]
}

@test "dots-preamble falls back when the heading is not the first output" {
    stub_tilth_text $'\n# tilth agent preamble\n'
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    stub_tilth_text $'warning: x\n# tilth agent preamble\n'
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    [ ! -e "$HOME/.cache/dotfiles" ]
}

@test "dots-preamble keeps the exact bytes of a dotfiles preamble without a final newline" {
    stub_tilth preamble
    printf 'no newline' > "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    local joined="$output"
    [ "$(tail -c 10 "$joined" | od -An -c | tr -d ' \n')" = "nonewline" ]
    cmp <(tail -c "$(wc -c < "$AGENTS_DOTFILES/preamble.md")" "$joined") "$AGENTS_DOTFILES/preamble.md"
}

@test "concurrent dots-preamble runs on a cold cache agree and leave no temp file" {
    stub_tilth preamble
    local i
    for i in 1 2 3 4 5 6; do
        "$REAL_DOTFILES_DIR/bin/dots-preamble" > "$TEST_HOME/out.$i" &
    done
    wait
    local first
    first=$(cat "$TEST_HOME/out.1")
    for i in 2 3 4 5 6; do
        [ "$(cat "$TEST_HOME/out.$i")" = "$first" ]
    done
    [ "$(cat "$first")" = $'# tilth agent preamble\n\nbase rule\n\n# Execution preamble' ]
    [ -z "$(find "$HOME/.cache/dotfiles" -name 'preamble.*' -not -name 'preamble-*')" ]
    [ "$(find "$HOME/.cache/dotfiles" -type f | wc -l)" -eq 1 ]
}

@test "dots_effective_preamble survives unset HOME and XDG_CACHE_HOME under set -u" {
    stub_tilth preamble
    # shellcheck disable=SC2016  # the inner bash expands $1 and $2
    run env -u HOME -u XDG_CACHE_HOME bash -c '
        set -euo pipefail
        source "$1/bin/lib/preamble-wrappers.sh"
        p=$(dots_effective_preamble "$2")
        echo "path:$p"
        echo after
    ' _ "$REAL_DOTFILES_DIR" "$AGENTS_DOTFILES/preamble.md"
    [ "$status" -eq 0 ]
    # No absolute cache base exists, so the function prints the plain path.
    [ "$output" = "path:$AGENTS_DOTFILES/preamble.md"$'\nafter' ]
}

@test "dots-preamble treats an empty XDG_CACHE_HOME as unset" {
    stub_tilth preamble
    XDG_CACHE_HOME="" run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [[ "$output" == "$HOME/.cache/dotfiles/preamble-"*.md ]]
    [ -f "$output" ]
}

@test "dots-preamble reuses a cached file with equal content" {
    stub_tilth preamble
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    local cached="$output"
    # A hard link names the same inode; a rewrite through a rename breaks it.
    ln "$cached" "$TEST_HOME/cached-link"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$cached" ]
    [ "$cached" -ef "$TEST_HOME/cached-link" ]
}

@test "dots-preamble replaces a cached file whose content differs" {
    stub_tilth preamble
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    local cached="$output"
    printf 'planted\n' > "$cached"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$cached" ]
    [ "$(cat "$cached")" = $'# tilth agent preamble\n\nbase rule\n\n# Execution preamble' ]
}

@test "dotsclaude launches without a system prompt flag when the preamble is missing" {
    stub_tilth preamble
    rm "$AGENTS_DOTFILES/preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-p" ]
    [ "${lines[1]}" = "hi" ]
    [[ "$output" != *--system-prompt-file* ]]
}

# ── probe, cache trust, and cache hygiene ────────────────────────────────────

@test "dots-preamble probes tilth with preamble --path and nothing else" {
    stub_tilth preamble
    cat > "$TEST_HOME/fakebin/tilth" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> '$TEST_HOME/tilth-calls'
printf '%s\n' '$TEST_HOME/tilth-preamble.md'
SH
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$(cat "$TEST_HOME/tilth-calls")" = "preamble --path" ]
}

@test "dots-preamble falls back when tilth prints a path that does not exist" {
    stub_tilth preamble
    rm "$TEST_HOME/tilth-preamble.md"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
}

@test "dots-preamble creates the cache directory with mode 700" {
    stub_tilth preamble
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ -n "$(find "$HOME/.cache/dotfiles" -maxdepth 0 -perm 700)" ]
}

@test "dots-preamble refuses a cache directory that is a symlink" {
    stub_tilth preamble
    mkdir -p "$HOME/.cache" "$TEST_HOME/elsewhere"
    ln -s "$TEST_HOME/elsewhere" "$HOME/.cache/dotfiles"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    [ -z "$(find "$TEST_HOME/elsewhere" -type f)" ]
}

@test "dots-preamble refuses a cache directory that other users can write" {
    stub_tilth preamble
    mkdir -p "$HOME/.cache/dotfiles"
    chmod 777 "$HOME/.cache/dotfiles"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    [ -z "$(find "$HOME/.cache/dotfiles" -type f)" ]
    # Group write stays allowed: umask 002 gives it with a private group.
    chmod 775 "$HOME/.cache/dotfiles"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [[ "$output" == "$HOME/.cache/dotfiles/preamble-"*.md ]]
}

@test "dots-preamble falls back when the cache file name is a directory" {
    stub_tilth preamble
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    local cached="$output"
    rm "$cached"
    mkdir "$cached"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    [ -z "$(find "$cached" -type f)" ]
}

@test "dots-preamble deletes joined files older than 30 days after a new write" {
    stub_tilth preamble
    local dir="$HOME/.cache/dotfiles"
    mkdir -p "$dir"
    touch -t 202001010000 "$dir/preamble-1-1.md" "$dir/other.md"
    touch "$dir/preamble-2-2.md"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ -f "$output" ]
    [ ! -e "$dir/preamble-1-1.md" ]
    [ -f "$dir/preamble-2-2.md" ]
    [ -f "$dir/other.md" ]
}

@test "dots-preamble removes its temporary file when the rename fails" {
    stub_tilth preamble
    printf '%s\n' '#!/bin/sh' 'exit 1' > "$TEST_HOME/fakebin/mv"
    chmod +x "$TEST_HOME/fakebin/mv"
    run "$REAL_DOTFILES_DIR/bin/dots-preamble"
    [ "$status" -eq 0 ]
    [ "$output" = "$AGENTS_DOTFILES/preamble.md" ]
    [ -z "$(find "$HOME/.cache/dotfiles" -type f)" ]
}

# ── dotsclaude through a file symlink ────────────────────────────────────────

@test "dotsclaude through a file symlink finds the library in DOTFILES_DIR" {
    stub_tilth preamble
    local clone="$TEST_HOME/clone"
    mkdir -p "$clone/bin/lib" "$TEST_HOME/elsewhere"
    cp "$REAL_DOTFILES_DIR/bin/lib/preamble-wrappers.sh" "$clone/bin/lib/"
    ln -s "$REAL_DOTFILES_DIR/bin/dotsclaude" "$TEST_HOME/elsewhere/dotsclaude"
    DOTFILES_DIR="$clone" run "$TEST_HOME/elsewhere/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [[ "${lines[1]}" == "$HOME/.cache/dotfiles/preamble-"*.md ]]
    [ "${lines[2]}" = "-p" ]
    [ "${lines[3]}" = "hi" ]
}

@test "dotsclaude through a file symlink without a library passes the dotfiles preamble" {
    stub_tilth preamble
    mkdir -p "$TEST_HOME/elsewhere"
    ln -s "$REAL_DOTFILES_DIR/bin/dotsclaude" "$TEST_HOME/elsewhere/dotsclaude"
    run "$TEST_HOME/elsewhere/dotsclaude" -p hi
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "--system-prompt-file" ]
    [ "${lines[1]}" = "$AGENTS_DOTFILES/preamble.md" ]
    [ "${lines[2]}" = "-p" ]
    [ "${lines[3]}" = "hi" ]
}
