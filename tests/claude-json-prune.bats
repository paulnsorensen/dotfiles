#!/usr/bin/env bats
# Tests for claude-json-prune — stale project entry removal from ~/.claude.json
#
# Safety-critical: this script modifies a file Claude Code depends on,
# so we test thoroughly in an isolated temp directory.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PATH="$DOTFILES_DIR/bin:$PATH"

# ── Helpers ───────────────────────────────────────────────────────────

# Strip ANSI escape codes for assertion matching
strip_ansi() {
  printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'
}

assert_success() {
  [[ $status -eq 0 ]] || {
    echo "Expected success, got status $status"
    echo "Output: $output"
    return 1
  }
}

assert_failure() {
  [[ $status -ne 0 ]] || {
    echo "Expected failure, got success"
    echo "Output: $output"
    return 1
  }
}

assert_contains() {
  local clean
  clean=$(strip_ansi "${2:-$output}")
  [[ "$clean" == *"$1"* ]] || {
    echo "Output does not contain: $1"
    echo "Actual: $clean"
    return 1
  }
}

assert_not_contains() {
  local clean
  clean=$(strip_ansi "${2:-$output}")
  [[ "$clean" != *"$1"* ]] || {
    echo "Output should not contain: $1"
    echo "Actual: $clean"
    return 1
  }
}

# Create a minimal .claude.json with given project paths
# Usage: make_claude_json path1 path2 ...
make_claude_json() {
  local projects="{}"
  for p in "$@"; do
    projects=$(echo "$projects" | jq --arg k "$p" '. + {($k): {"allowedTools": []}}')
  done
  jq -n --argjson projects "$projects" '{
    "numStartups": 10,
    "installMethod": "native",
    "projects": $projects
  }'
}

setup() {
  TEST_DIR=$(mktemp -d)
  export CLAUDE_JSON="$TEST_DIR/claude.json"
  export BACKUP_DIR="$TEST_DIR/backups"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ── Missing file / dependency checks ─────────────────────────────────

@test "exits with error when .claude.json does not exist" {
  rm -f "$CLAUDE_JSON"
  run claude-json-prune
  assert_failure
  assert_contains "No ~/.claude.json found"
}

# ── Dry-run mode (default) ───────────────────────────────────────────

@test "dry run shows stale entry count" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/fake-project" > "$CLAUDE_JSON"

  run claude-json-prune
  assert_success
  assert_contains "1 stale entries"
  assert_contains "/nonexistent/fake-project"
  assert_contains "claude-json-prune --apply"
}

@test "dry run does not modify the file" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/a" "/nonexistent/b" > "$CLAUDE_JSON"

  local before
  before=$(md5 -q "$CLAUDE_JSON")
  run claude-json-prune
  assert_success
  local after
  after=$(md5 -q "$CLAUDE_JSON")
  [[ "$before" = "$after" ]] || {
    echo "File was modified during dry run!"
    return 1
  }
}

@test "dry run reports clean when no stale entries" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" > "$CLAUDE_JSON"

  run claude-json-prune
  assert_success
  assert_contains "No stale entries found"
  assert_contains "Already clean"
}

@test "dry run shows project count and line count" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/x" > "$CLAUDE_JSON"

  run claude-json-prune
  assert_success
  assert_contains "Projects: 2"
}

# ── Apply mode ───────────────────────────────────────────────────────

@test "apply removes stale entries" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/a" "/nonexistent/b" > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success
  assert_contains "Pruned 2 stale entries"

  # Verify the file only has the real project
  local remaining
  remaining=$(jq -r '.projects | keys[]' "$CLAUDE_JSON")
  [[ "$remaining" = "$real_dir" ]] || {
    echo "Expected only $real_dir, got: $remaining"
    return 1
  }
}

@test "apply preserves non-project top-level keys" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/x" > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success

  # Verify top-level keys survived
  local startups
  startups=$(jq '.numStartups' "$CLAUDE_JSON")
  [[ "$startups" = "10" ]] || {
    echo "numStartups was lost or corrupted: $startups"
    return 1
  }
  local method
  method=$(jq -r '.installMethod' "$CLAUDE_JSON")
  [[ "$method" = "native" ]] || {
    echo "installMethod was lost or corrupted: $method"
    return 1
  }
}

@test "apply preserves project data for kept entries" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"

  # Create with richer project data
  jq -n --arg real "$real_dir" '{
    "numStartups": 5,
    "projects": {
      ($real): {"allowedTools": ["Bash"], "lastCost": 3.14, "hasTrustDialogAccepted": true},
      "/nonexistent/stale": {"allowedTools": [], "lastCost": 99.99}
    }
  }' > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success

  # Verify kept project data is intact
  local cost
  cost=$(jq --arg p "$real_dir" '.projects[$p].lastCost' "$CLAUDE_JSON")
  [[ "$cost" = "3.14" ]] || {
    echo "Project data corrupted — lastCost: $cost"
    return 1
  }
  local trust
  trust=$(jq --arg p "$real_dir" '.projects[$p].hasTrustDialogAccepted' "$CLAUDE_JSON")
  [[ "$trust" = "true" ]] || {
    echo "Project data corrupted — hasTrustDialogAccepted: $trust"
    return 1
  }
}

@test "apply creates backup before modifying" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/x" > "$CLAUDE_JSON"

  local original
  original=$(cat "$CLAUDE_JSON")

  run claude-json-prune --apply
  assert_success
  assert_contains "Backup:"

  # Verify backup directory was created and has a file
  [[ -d "$BACKUP_DIR" ]] || {
    echo "Backup directory was not created"
    return 1
  }
  local backup_count
  backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -name 'claude.json.*' | wc -l | tr -d ' ')
  [[ "$backup_count" -eq 1 ]] || {
    echo "Expected 1 backup file, found $backup_count"
    return 1
  }

  # Verify backup content matches original
  local backup_file
  backup_file=$(find "$BACKUP_DIR" -maxdepth 1 -name 'claude.json.*' -print -quit)
  local backup_content
  backup_content=$(cat "$backup_file")
  [[ "$backup_content" = "$original" ]] || {
    echo "Backup content does not match original"
    return 1
  }
}

@test "apply with no stale entries does nothing" {
  local real_dir="$TEST_DIR/real-project"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" > "$CLAUDE_JSON"

  local before
  before=$(md5 -q "$CLAUDE_JSON")
  run claude-json-prune --apply
  assert_success
  assert_contains "Already clean"

  local after
  after=$(md5 -q "$CLAUDE_JSON")
  [[ "$before" = "$after" ]] || {
    echo "File was modified when no pruning needed!"
    return 1
  }

  # No backup should be created
  [[ ! -d "$BACKUP_DIR" ]] || {
    local count
    count=$(find "$BACKUP_DIR" -maxdepth 1 -name 'claude.json.*' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" -eq 0 ]] || {
      echo "Backup created when no changes were made"
      return 1
    }
  }
}

# ── Edge cases ───────────────────────────────────────────────────────

@test "handles empty projects object" {
  jq -n '{"numStartups": 1, "projects": {}}' > "$CLAUDE_JSON"

  run claude-json-prune
  assert_success
  assert_contains "Projects: 0"
  assert_contains "Already clean"
}

@test "handles all entries being stale" {
  make_claude_json "/nonexistent/a" "/nonexistent/b" "/nonexistent/c" > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success
  assert_contains "Pruned 3 stale entries"

  local remaining
  remaining=$(jq '.projects | keys | length' "$CLAUDE_JSON")
  [[ "$remaining" -eq 0 ]] || {
    echo "Expected 0 projects after pruning all, got $remaining"
    return 1
  }
}

@test "handles paths with spaces" {
  local spaced_dir="$TEST_DIR/my project"
  mkdir -p "$spaced_dir"
  make_claude_json "$spaced_dir" "/nonexistent/path with spaces" > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success
  assert_contains "Pruned 1 stale entries"

  local remaining
  remaining=$(jq -r '.projects | keys[]' "$CLAUDE_JSON")
  [[ "$remaining" = "$spaced_dir" ]] || {
    echo "Path with spaces not handled correctly: $remaining"
    return 1
  }
}

@test "output is valid JSON after apply" {
  local real_dir="$TEST_DIR/real"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/a" "/nonexistent/b" > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success

  # jq will fail if the output isn't valid JSON
  run jq '.' "$CLAUDE_JSON"
  assert_success
}

@test "multiple applies are idempotent" {
  local real_dir="$TEST_DIR/real"
  mkdir -p "$real_dir"
  make_claude_json "$real_dir" "/nonexistent/a" > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success
  assert_contains "Pruned 1 stale entries"

  local after_first
  after_first=$(cat "$CLAUDE_JSON")

  run claude-json-prune --apply
  assert_success
  assert_contains "Already clean"

  local after_second
  after_second=$(cat "$CLAUDE_JSON")
  [[ "$after_first" = "$after_second" ]] || {
    echo "Second apply changed the file!"
    return 1
  }
}

@test "handles many stale entries efficiently" {
  # Build a JSON with 50 stale paths + 1 real
  local real_dir="$TEST_DIR/real"
  mkdir -p "$real_dir"
  local args=("$real_dir")
  for i in $(seq 1 50); do
    args+=("/nonexistent/workspace-$i")
  done
  make_claude_json "${args[@]}" > "$CLAUDE_JSON"

  run claude-json-prune --apply
  assert_success
  assert_contains "Pruned 50 stale entries"

  local remaining
  remaining=$(jq '.projects | keys | length' "$CLAUDE_JSON")
  [[ "$remaining" -eq 1 ]]
}
