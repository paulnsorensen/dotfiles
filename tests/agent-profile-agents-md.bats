#!/usr/bin/env bats
# shellcheck disable=SC1090,SC2034,SC2317
# Tests for the "## Agent Profiles" section of AGENTS.md (post-reshape state).
# Asserts the 5-harness matrix, shared-path strategy, models: schema, and the
# absence of the reshape-warning callout.

load test_helper

setup() {
    setup_test_env
    AGENTS_MD="$REAL_DOTFILES_DIR/AGENTS.md"
    SECTION_FILE="$TEST_HOME/agent-profiles-section.md"
    # Extract the "## Agent Profiles" section: from the heading line up to (but
    # not including) the next "## " heading. awk is used because grep -A can't
    # cleanly handle "until next match" semantics.
    awk '
        /^## Agent Profiles/ { capture = 1; print; next }
        capture && /^## / { capture = 0 }
        capture { print }
    ' "$AGENTS_MD" > "$SECTION_FILE"
    [[ -s "$SECTION_FILE" ]]
}

teardown() { teardown_test_env; }

@test "AGENTS.md Agent Profiles section exists and is non-empty" {
    run wc -l "$SECTION_FILE"
    assert_success
    # Sanity floor — the rewritten section is much longer than a single heading.
    local lines
    lines=$(wc -l < "$SECTION_FILE")
    [[ "$lines" -gt 20 ]]
}

@test "matrix lists all 5 harness names" {
    grep -q 'Claude'    "$SECTION_FILE"
    grep -q 'Codex'     "$SECTION_FILE"
    grep -q 'opencode'  "$SECTION_FILE"
    grep -q 'Cursor'    "$SECTION_FILE"
    grep -q 'Copilot'   "$SECTION_FILE"
}

@test "matrix header row contains all 5 harnesses on one line" {
    # The matrix table header should mention every harness, proving they're all
    # columns in the same matrix rather than scattered prose mentions.
    grep -E '\| *Claude *\| *Codex *\| *opencode *\| *Cursor *\| *Copilot' \
        "$SECTION_FILE"
}

@test "shared-path strategy mentions .agents/skills/" {
    grep -q '\.agents/skills/' "$SECTION_FILE"
}

@test "shared-path strategy mentions .claude/agents/" {
    grep -q '\.claude/agents/' "$SECTION_FILE"
}

@test "models: schema is documented as a per-harness map" {
    # The literal token "models:" must appear, and the surrounding prose must
    # frame it as a per-harness override map.
    grep -q 'models:' "$SECTION_FILE"
    grep -qi 'per-harness' "$SECTION_FILE"
}

@test "inherit sentinel is documented" {
    grep -q 'inherit' "$SECTION_FILE"
}

@test "no reshape-warning [!NOTE] callout in the section" {
    ! grep -q '\[!NOTE\]' "$SECTION_FILE"
    ! grep -qi 'reshape lands in follow-up commits' "$SECTION_FILE"
}

@test "section no longer claims AGENTS.md splice (TBD sidecar) behaviour" {
    # The old text mentioned a "profile-scoped sidecar file (TBD)" — that
    # speculative wording must be gone now that the design is implemented.
    ! grep -qi 'sidecar file (TBD)' "$SECTION_FILE"
}
