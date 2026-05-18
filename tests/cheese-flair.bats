#!/usr/bin/env bats
# Tests for agents/lib/cheese-flair.sh — name generator and quote picker
# backing the SessionStart cheese-flair hook. Lives under agents/ because
# the lib is harness-agnostic and consumed by both Claude and Codex.

load test_helper

LIB="$REAL_DOTFILES_DIR/agents/lib/cheese-flair.sh"
BANK="$REAL_DOTFILES_DIR/agents/reference/cheese-flair.md"

setup() {
    export CHEESE_FLAIR_BANK="$BANK"
}

@test "bank file exists" {
    assert_file_exists "$BANK"
}

@test "lib script exists and is executable" {
    assert_file_exists "$LIB"
    [[ -x "$LIB" ]]
}

@test "hook script exists and is executable" {
    local hook="$REAL_DOTFILES_DIR/agents/hooks/session-start-cheese-flair.sh"
    assert_file_exists "$hook"
    [[ -x "$hook" ]]
}

@test "cheese_curated_name returns a name from the curated list" {
    # shellcheck source=/dev/null
    source "$LIB"
    local name
    name="$(cheese_curated_name)"
    [[ -n "$name" ]]
    grep -qxF -- "- $name" "$BANK"
}

@test "cheese_generate_name produces adjective + title with cheese substituted" {
    # shellcheck source=/dev/null
    source "$LIB"
    local name
    name="$(cheese_generate_name)"
    [[ -n "$name" ]]
    [[ "$name" != *"{C}"* ]]
    # Generated names are at least two words: "<Adjective> <Title with cheese>"
    local word_count
    word_count="$(printf '%s' "$name" | wc -w | tr -d ' ')"
    [[ "$word_count" -ge 2 ]]
}

@test "cheese_name curated is always from the curated list" {
    # shellcheck source=/dev/null
    source "$LIB"
    local name
    name="$(cheese_name curated)"
    grep -qxF -- "- $name" "$BANK"
}

@test "cheese_name generated never leaks the {C} placeholder" {
    # shellcheck source=/dev/null
    source "$LIB"
    for _ in 1 2 3 4 5; do
        local name
        name="$(cheese_name generated)"
        [[ "$name" != *"{C}"* ]]
    done
}

@test "cheese_name mixed produces non-empty output" {
    # shellcheck source=/dev/null
    source "$LIB"
    for _ in 1 2 3 4 5; do
        local name
        name="$(cheese_name mixed)"
        [[ -n "$name" ]]
    done
}

@test "cheese_name unknown mode fails with diagnostic" {
    run bash -c "source '$LIB' && cheese_name borked 2>&1"
    assert_failure
    assert_output_contains "unknown mode"
}

@test "cheese_quote returns 'Universe — quote' format" {
    # shellcheck source=/dev/null
    source "$LIB"
    local quote
    quote="$(cheese_quote)"
    [[ -n "$quote" ]]
    [[ "$quote" == *" — "* ]]
}

@test "cheese_quote universes cover all five expected sources" {
    # shellcheck source=/dev/null
    source "$LIB"
    local seen
    seen="$(for _ in $(seq 1 200); do cheese_quote; done | awk -F' — ' '{print $1}' | sort -u)"
    [[ "$seen" == *"Dune"* ]]
    [[ "$seen" == *"Mad Max: Fury Road"* ]]
    [[ "$seen" == *"Monty Python's Holy Grail"* ]]
    [[ "$seen" == *"The Princess Bride"* ]]
    [[ "$seen" == *"The Lord of the Rings"* ]]
}

@test "cheese_sample emits Addresses and Quotes lines" {
    # shellcheck source=/dev/null
    source "$LIB"
    run cheese_sample
    assert_success
    assert_output_contains "Addresses:"
    assert_output_contains "Quotes:"
}

@test "CLI: sample subcommand produces hook-shaped output" {
    run bash "$LIB" sample
    assert_success
    assert_output_contains "Cheese flair"
    assert_output_contains "Addresses:"
}

@test "CLI: name subcommand defaults to weighted and is non-empty" {
    run bash "$LIB" name
    assert_success
    [[ -n "$output" ]]
}

@test "cheese_big_hitter returns a name from the Big hitters list" {
    # shellcheck source=/dev/null
    source "$LIB"
    local name
    name="$(cheese_big_hitter)"
    [[ -n "$name" ]]
    grep -qxF -- "- $name" "$BANK"
}

@test "cheese_name weighted returns Cheese Lord roughly half the time" {
    # shellcheck source=/dev/null
    source "$LIB"
    local lord_count=0 total=200
    for _ in $(seq 1 "$total"); do
        if [[ "$(cheese_name weighted)" == "Cheese Lord" ]]; then
            lord_count=$((lord_count + 1))
        fi
    done
    # Target 50%, allow wide tolerance: 30-70% across 200 draws.
    [[ "$lord_count" -ge 60 ]]
    [[ "$lord_count" -le 140 ]]
}

@test "cheese_name weighted hits big-hitters and wider bank too" {
    # shellcheck source=/dev/null
    source "$LIB"
    local big_hitter_count=0 wider_count=0 lord_count=0
    local big_hitters
    big_hitters="$(awk '
        /^## Big hitters/ { in_section = 1; next }
        /^## / { in_section = 0 }
        in_section && /^- / { sub(/^- /, ""); print }
    ' "$BANK")"
    for _ in $(seq 1 200); do
        local name
        name="$(cheese_name weighted)"
        if [[ "$name" == "Cheese Lord" ]]; then
            lord_count=$((lord_count + 1))
        elif printf '%s\n' "$big_hitters" | grep -qxF -- "$name"; then
            big_hitter_count=$((big_hitter_count + 1))
        else
            wider_count=$((wider_count + 1))
        fi
    done
    # All three buckets must be reached at least once.
    [[ "$lord_count" -gt 0 ]]
    [[ "$big_hitter_count" -gt 0 ]]
    [[ "$wider_count" -gt 0 ]]
}

@test "cheese_quotes 3 returns three distinct lines" {
    # shellcheck source=/dev/null
    source "$LIB"
    local quotes line_count distinct_count
    quotes="$(cheese_quotes 3)"
    line_count="$(printf '%s\n' "$quotes" | wc -l | tr -d ' ')"
    [[ "$line_count" -eq 3 ]]
    distinct_count="$(printf '%s\n' "$quotes" | sort -u | wc -l | tr -d ' ')"
    [[ "$distinct_count" -eq 3 ]]
}

@test "cheese_names 3 returns three distinct lines" {
    # shellcheck source=/dev/null
    source "$LIB"
    for _ in 1 2 3 4 5; do
        local names line_count distinct_count
        names="$(cheese_names 3)"
        line_count="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
        [[ "$line_count" -eq 3 ]]
        distinct_count="$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')"
        [[ "$distinct_count" -eq 3 ]]
    done
}

@test "cheese_sample emits three address bullets and three quote bullets" {
    # shellcheck source=/dev/null
    source "$LIB"
    local sample bullets
    sample="$(cheese_sample)"
    bullets="$(printf '%s\n' "$sample" | grep -c '^  - ')"
    [[ "$bullets" -eq 6 ]]
}

@test "cheese_sample always pins Cheese Lord as the first address" {
    # shellcheck source=/dev/null
    source "$LIB"
    for _ in 1 2 3 4 5; do
        local sample first
        sample="$(cheese_sample)"
        first="$(printf '%s\n' "$sample" | awk '/^- Addresses:/ { found = 1; next } /^- Quotes:/ { exit } found && /^  - / { sub(/^  - /, ""); print }' | head -n 1)"
        [[ "$first" == "Cheese Lord" ]]
    done
}

@test "cheese_sample addresses are distinct across all three slots" {
    # shellcheck source=/dev/null
    source "$LIB"
    for _ in 1 2 3 4 5; do
        local addresses distinct_count
        addresses="$(cheese_sample | awk '/^- Addresses:/ { found = 1; next } /^- Quotes:/ { found = 0 } found && /^  - / { sub(/^  - /, ""); print }')"
        distinct_count="$(printf '%s\n' "$addresses" | sort -u | wc -l | tr -d ' ')"
        [[ "$distinct_count" -eq 3 ]]
    done
}

@test "CLI: names subcommand defaults to 3 distinct draws" {
    run bash "$LIB" names
    assert_success
    local line_count distinct_count
    line_count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
    [[ "$line_count" -eq 3 ]]
    distinct_count="$(printf '%s\n' "$output" | sort -u | wc -l | tr -d ' ')"
    [[ "$distinct_count" -eq 3 ]]
}

@test "CLI: name curated subcommand returns a curated entry" {
    run bash "$LIB" name curated
    assert_success
    grep -qxF -- "- $output" "$BANK"
}

@test "CLI: quote subcommand returns 'Universe — quote'" {
    run bash "$LIB" quote
    assert_success
    [[ "$output" == *" — "* ]]
}

@test "CLI: invalid subcommand prints usage and exits non-zero" {
    run bash -c "bash '$LIB' not-a-thing 2>&1"
    assert_failure
    assert_output_contains "Usage:"
}

# ── hardening: self-locating hook script under deployed layout ────────
# These tests simulate the chezmoi-deployed layout under a temp $HOME
# and run the hook script directly — no CHEESE_FLAIR_BANK override — so
# the script's $SCRIPT_DIR/../{lib,reference} resolution must do the work.

_deploy_harness_layout() {
    local harness="$1" root="$2"
    mkdir -p "$root/.$harness/hooks" "$root/.$harness/lib" "$root/.$harness/reference"
    cp "$REAL_DOTFILES_DIR/agents/hooks/session-start-cheese-flair.sh" "$root/.$harness/hooks/"
    cp "$REAL_DOTFILES_DIR/agents/lib/cheese-flair.sh"                 "$root/.$harness/lib/"
    cp "$REAL_DOTFILES_DIR/agents/reference/cheese-flair.md"           "$root/.$harness/reference/"
    chmod +x "$root/.$harness/hooks/session-start-cheese-flair.sh"
}

@test "hook script self-locates lib + bank under deployed ~/.claude layout" {
    local root="${TMPDIR:-/tmp}/cheese-flair-deploy-claude-$$"
    rm -rf "$root"
    _deploy_harness_layout claude "$root"

    # Critically: no CHEESE_FLAIR_BANK env var → script must self-locate.
    run bash -c "unset CHEESE_FLAIR_BANK; HOME='$root' bash '$root/.claude/hooks/session-start-cheese-flair.sh'"
    assert_success
    assert_output_contains "Cheese flair"
    assert_output_contains "Addresses:"
    assert_output_contains "Quotes:"
    # First address bullet must be pinned.
    [[ "$output" == *"  - Cheese Lord"* ]]

    rm -rf "$root"
}

@test "hook script self-locates lib + bank under deployed ~/.codex layout" {
    local root="${TMPDIR:-/tmp}/cheese-flair-deploy-codex-$$"
    rm -rf "$root"
    _deploy_harness_layout codex "$root"

    run bash -c "unset CHEESE_FLAIR_BANK; HOME='$root' bash '$root/.codex/hooks/session-start-cheese-flair.sh'"
    assert_success
    assert_output_contains "Cheese flair"
    assert_output_contains "Addresses:"
    assert_output_contains "Quotes:"
    [[ "$output" == *"  - Cheese Lord"* ]]

    rm -rf "$root"
}

@test "hook script silently no-ops with exit 0 when its lib is missing" {
    local root="${TMPDIR:-/tmp}/cheese-flair-no-lib-$$"
    rm -rf "$root"
    _deploy_harness_layout claude "$root"
    rm "$root/.claude/lib/cheese-flair.sh"

    run bash -c "unset CHEESE_FLAIR_BANK; HOME='$root' bash '$root/.claude/hooks/session-start-cheese-flair.sh'"
    assert_success
    [[ -z "$output" ]]

    rm -rf "$root"
}

@test "hook script output shape matches across both harnesses (3 addresses + 3 quotes)" {
    # Spec acceptance criterion #5: Codex hook output shape matches Claude.
    local root="${TMPDIR:-/tmp}/cheese-flair-shape-$$"
    rm -rf "$root"
    _deploy_harness_layout claude "$root"
    _deploy_harness_layout codex  "$root"

    local claude_bullets codex_bullets
    claude_bullets=$(bash -c "unset CHEESE_FLAIR_BANK; HOME='$root' bash '$root/.claude/hooks/session-start-cheese-flair.sh'" | grep -c '^  - ')
    codex_bullets=$( bash -c "unset CHEESE_FLAIR_BANK; HOME='$root' bash '$root/.codex/hooks/session-start-cheese-flair.sh'"  | grep -c '^  - ')
    [[ "$claude_bullets" -eq 6 ]]
    [[ "$codex_bullets"  -eq 6 ]]

    rm -rf "$root"
}

# ── hardening: lib bank fallback chain ─────────────────────────────────

@test "lib sources its bank from ~/.codex when ~/.claude is absent and no env override" {
    local root="${TMPDIR:-/tmp}/cheese-flair-codex-only-$$"
    rm -rf "$root"
    mkdir -p "$root/.codex/reference"
    cp "$REAL_DOTFILES_DIR/agents/reference/cheese-flair.md" "$root/.codex/reference/"

    run bash -c "unset CHEESE_FLAIR_BANK; HOME='$root' bash '$LIB' quote"
    assert_success
    [[ "$output" == *" — "* ]]

    rm -rf "$root"
}

@test "lib CLI emits 'bank not found' diagnostic and exits non-zero when no bank exists" {
    local root="${TMPDIR:-/tmp}/cheese-flair-nobank-$$"
    rm -rf "$root"
    mkdir -p "$root"

    run bash -c "unset CHEESE_FLAIR_BANK; HOME='$root' bash '$LIB' name 2>&1"
    assert_failure
    assert_output_contains "bank not found"

    rm -rf "$root"
}
