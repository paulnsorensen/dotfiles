# shellcheck shell=bash
# preamble-wrappers.sh — launch logic for bin/dotsclaude, bin/dotscodex,
# bin/dotsopencode, and bin/dots-preamble. Claude and Codex get the tilth
# preamble joined with agents/preamble.md as their system prompt. OpenCode
# gets agents/preamble.md. The wrappers only parse and dispatch; the logic
# lives here. Functions only — no top-level side effects, so sourcing is safe
# from bats tests. Bash 3.2 compatible (macOS /bin/bash).

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

# dots_effective_preamble <dotfiles-preamble-path>
# Prints the path of the system-prompt file for Claude and Codex.
# When `tilth preamble` works, the file holds the tilth preamble and then the
# dotfiles preamble. tilth owns the tool rules and ships them with its binary.
# The file is in the cache directory, with a content checksum in its name, so
# a running session keeps its file when the content changes.
# When tilth is missing or too old, or the cache write fails, the function
# prints the dotfiles preamble path. Returns 1 when that file is missing.
dots_effective_preamble() {
    local addendum="$1" base dir sum out tmp
    [[ -f "$addendum" ]] || return 1
    base="$(tilth preamble 2>/dev/null)" || base=""
    # A tilth without the subcommand searches for the word "preamble".
    if [[ "$base" != "# tilth agent preamble"* ]]; then
        printf '%s\n' "$addendum"
        return 0
    fi
    # A relative or empty XDG_CACHE_HOME is not valid; use the home default.
    dir="${XDG_CACHE_HOME:-}"
    [[ "$dir" == /* ]] || dir="${HOME:-}/.cache"
    dir="$dir/dotfiles"
    sum="$(_dots_join_preamble "$base" "$addendum" | cksum)"
    out="$dir/preamble-${sum// /-}.md"
    if [[ ! -f "$out" ]]; then
        if ! { mkdir -p "$dir" 2>/dev/null \
            && tmp="$(mktemp "$dir/preamble.XXXXXX" 2>/dev/null)" \
            && _dots_join_preamble "$base" "$addendum" >"$tmp" \
            && mv "$tmp" "$out"; }; then
            printf '%s\n' "$addendum"
            return 0
        fi
    fi
    printf '%s\n' "$out"
}

# _dots_join_preamble <tilth-preamble-text> <dotfiles-preamble-path>
# Prints the tilth preamble, an empty line, and the dotfiles preamble.
_dots_join_preamble() {
    printf '%s\n\n' "$1"
    cat "$2"
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
