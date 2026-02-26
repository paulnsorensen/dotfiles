#!/usr/bin/env bash
# Monitor-specific test helpers for claude-monitor bats tests

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MONITOR="$DOTFILES_DIR/bin/claude-monitor"

strip_ansi() {
    printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*[mK]//g'
}

assert_contains() {
    local haystack
    haystack="$(strip_ansi "${output:-}")"
    [[ "$haystack" == *"$1"* ]] || {
        echo "Output does not contain: $1"
        echo "Actual: $haystack"
        return 1
    }
}

assert_not_contains() {
    local haystack
    haystack="$(strip_ansi "${output:-}")"
    [[ "$haystack" != *"$1"* ]] || {
        echo "Output should NOT contain: $1"
        echo "Actual: $haystack"
        return 1
    }
}

setup() {
    TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-monitor-test.XXXXXX")"
    FAKE_HOME="$TEST_TMP/fake_home"
    mkdir -p "$FAKE_HOME"
}

teardown() {
    rm -rf "$TEST_TMP" 2>/dev/null || true
}

make_assistant_entry() {
    local it="${1:-100}" cr="${2:-50}" cc="${3:-20}" ot="${4:-30}"
    local model="${5:-claude-opus-4-6}" mid="${6:-msg_abc123}" ts="${7:-2025-01-01T12:00:00.000Z}"
    printf '{"type":"assistant","message":{"id":"%s","model":"%s","content":[],"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":%s}},"timestamp":"%s"}\n' \
        "$mid" "$model" "$it" "$cr" "$cc" "$ot" "$ts"
}

make_user_entry() {
    local ts="${1:-2025-01-01T12:00:00.000Z}"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"toolUseResult":null,"timestamp":"%s"}\n' "$ts"
}

make_tool_use_entry() {
    local name="${1:-Bash}" mid="${2:-msg_tool1}" ts="${3:-2025-01-01T12:00:00.000Z}"
    printf '{"type":"assistant","message":{"id":"%s","model":"claude-opus-4-6","content":[{"type":"tool_use","name":"%s","id":"tu1","input":{}}],"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}},"timestamp":"%s"}\n' \
        "$mid" "$name" "$ts"
}

make_project() {
    local encoded="${1//[\/.]/-}"
    local proj_dir="$FAKE_HOME/.claude/projects/${encoded}"
    mkdir -p "$proj_dir"
    echo "$proj_dir"
}
