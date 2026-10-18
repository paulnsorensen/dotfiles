# shellcheck shell=bash
# preamble-wrappers.sh — launch logic for bin/dotscodex and bin/dotsopencode.
# Each wrapper replaces its harness's native system prompt with
# agents/preamble.md. The wrappers only parse and dispatch; the logic lives
# here. Functions only — no top-level side effects, so sourcing is safe from
# bats tests. Bash 3.2 compatible (macOS /bin/bash).

# dots_codex_instructions_override <preamble-path>
# Prints the `-c` value that sets model_instructions_file to the path.
# The value is TOML: the path is quoted, with \ and " escaped.
# Returns 1 when the preamble file is missing.
dots_codex_instructions_override() {
    local preamble="$1" escaped
    [[ -f "$preamble" ]] || return 1
    escaped="${preamble//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf 'model_instructions_file="%s"\n' "$escaped"
}

# dots_opencode_preamble_path <agents-dotfiles-dir>
# Prints the preamble path for the OpenCode `instructions` list.
# The installed copy wins, as the literal string ~/.config/opencode/preamble.md.
# That string equals the global opencode.json entry, so OpenCode loads the
# file once. The clone copy is the fallback. Returns 1 when neither exists.
dots_opencode_preamble_path() {
    local agents_dir="$1"
    if [[ -f "$HOME/.config/opencode/preamble.md" ]]; then
        # shellcheck disable=SC2088 # literal tilde, see above
        printf '%s\n' "~/.config/opencode/preamble.md"
    elif [[ -f "$agents_dir/preamble.md" ]]; then
        printf '%s\n' "$agents_dir/preamble.md"
    else
        return 1
    fi
}

# dots_opencode_config <preamble-path> [incoming-json]
# Prints the OPENCODE_CONFIG_CONTENT value: the work-agent prompts and the
# preamble path, merged under the incoming config. Incoming keys win, except
# that an incoming `instructions` array is appended to the preamble path,
# without duplicates, so the caller cannot drop the preamble. An empty
# incoming value counts as {}. The prompts match
# chezmoi/.chezmoidata/opencode.yaml; tests/dots-wrappers.bats asserts this.
# Returns 1 when the incoming value is not a JSON object. Requires jq.
dots_opencode_config() {
    local preamble="$1" incoming="${2:-}"
    [[ -n "$incoming" ]] || incoming='{}'
    jq -cn --arg preamble "$preamble" --arg incoming "$incoming" '
        ($incoming | fromjson? // error("not JSON")) as $theirs |
        if ($theirs | type) != "object" then error("not an object") else . end |
        "Follow the shared execution preamble and applicable project instructions." as $base |
        ({
            instructions: [$preamble],
            agent: {
                build: {prompt: $base},
                plan: {prompt: ($base + " Plan only. Do not change workspace files.")},
                general: {prompt: $base},
                explore: {prompt: ($base + " Read only. Do not change files.")}
            }
        } * $theirs) |
        if ($theirs.instructions | type) == "array" then
            .instructions = (([$preamble] + $theirs.instructions)
                | reduce .[] as $p ([]; if any(.[]; . == $p) then . else . + [$p] end))
        else . end' 2>/dev/null
}
