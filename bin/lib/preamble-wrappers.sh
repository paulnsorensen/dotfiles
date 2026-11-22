# shellcheck shell=bash
# preamble-wrappers.sh — launch logic for bin/dotsclaude, bin/dotscodex,
# and bin/dotsopencode. Claude, Codex, and OpenCode get the
# tilth preamble joined with agents/preamble.md. The wrappers only parse and
# dispatch; the logic lives here. Functions only — no top-level side effects,
# so sourcing is safe from bats tests. Bash 3.2 compatible (macOS /bin/bash).

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
# Prints the path of the system-prompt file for Claude, Codex, and OpenCode.
# When `tilth preamble --path` works, the file holds the tilth preamble and
# then the dotfiles preamble. tilth owns the tool rules and ships them with
# its binary. The file is in a private cache directory, with a content
# checksum in its name, so a running session keeps its file when the content
# changes.
# The function prints the dotfiles preamble path when tilth is missing or too
# old, when no private cache directory is available, or when the cache write
# fails. Returns 1 when the dotfiles preamble is missing.
dots_effective_preamble() {
    local addendum="$1" base dir sum out tmp=""
    [[ -f "$addendum" ]] || return 1
    # A tilth without the subcommand rejects `--path` at once. Without the
    # flag, such a build searches the current directory for the word.
    base="$(tilth preamble --path 2>/dev/null)" || base=""
    if ! _dots_is_tilth_preamble "$base" || ! dir="$(_dots_preamble_cache_dir)" \
        || ! sum="$(_dots_join_preamble "$base" "$addendum" | cksum)"; then
        printf '%s\n' "$addendum"
        return 0
    fi
    out="$dir/preamble-${sum// /-}.md"
    # The checksum does not prove the content, so compare before reuse.
    if [[ -f "$out" && ! -L "$out" ]] \
        && _dots_join_preamble "$base" "$addendum" | cmp -s - "$out"; then
        printf '%s\n' "$out"
        return 0
    fi
    if [[ -d "$out" ]] || ! { tmp="$(mktemp "$dir/preamble.XXXXXX" 2>/dev/null)" \
        && _dots_join_preamble "$base" "$addendum" >"$tmp" \
        && mv -f "$tmp" "$out"; }; then
        [[ -z "$tmp" ]] || rm -f "$tmp"
        printf '%s\n' "$addendum"
        return 0
    fi
    _dots_prune_preambles "$dir"
    printf '%s\n' "$out"
}

# _dots_is_tilth_preamble <path>
# True when the file exists and its first line starts with the tilth heading.
_dots_is_tilth_preamble() {
    local first=""
    [[ -n "$1" && -f "$1" ]] || return 1
    IFS= read -r first <"$1" || [[ -n "$first" ]] || return 1
    [[ "$first" == "# tilth agent preamble"* ]]
}

# _dots_preamble_cache_dir
# Prints the private cache directory for joined preambles. It creates the
# directory with mode 700. Returns 1 when no absolute cache base exists, or
# when the directory is a symlink, has another owner, or lets other users
# write. tilth applies the same rules to its own cache. Group write stays
# allowed, because umask 002 gives it together with a private group.
_dots_preamble_cache_dir() {
    local base="${XDG_CACHE_HOME:-}" dir
    # A relative or empty XDG_CACHE_HOME is not valid; use the home default.
    [[ "$base" == /* ]] || base="${HOME:+$HOME/.cache}"
    [[ "$base" == /* ]] || return 1
    dir="$base/dotfiles"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$base" 2>/dev/null || return 1
        mkdir -m 700 "$dir" 2>/dev/null || [[ -d "$dir" ]] || return 1
    fi
    [[ ! -L "$dir" && -O "$dir" ]] || return 1
    [[ -z "$(find "$dir" -maxdepth 0 -perm -0002 2>/dev/null)" ]] || return 1
    printf '%s\n' "$dir"
}

# _dots_join_preamble <tilth-preamble-file> <dotfiles-preamble-path>
# Prints the tilth preamble, an empty line, and the dotfiles preamble.
_dots_join_preamble() {
    cat "$1" && printf '\n' && cat "$2"
}

# _dots_prune_preambles <cache-dir>
# Deletes joined preambles that are older than 30 days. A caller runs it
# after it writes a new file, so the new file is never a candidate.
_dots_prune_preambles() {
    find "$1" -maxdepth 1 -type f -name 'preamble-*.md' -mtime +30 \
        -exec rm -f {} + 2>/dev/null || true
}

# dots_opencode_preamble_path <agents-dotfiles-dir>
# Prints the preamble path for the OpenCode `instructions` list.
# The installed copy wins, as the literal string ~/.config/opencode/preamble.md.
# That string equals the global opencode.json entry, so OpenCode loads the
# file once. install-prompts.sh writes that copy from dots_effective_preamble.
# Without an installed copy, the function prints the dots_effective_preamble
# path for the clone copy. Returns 1 when neither exists.
dots_opencode_preamble_path() {
    local agents_dir="$1"
    if [[ -f "$HOME/.config/opencode/preamble.md" ]]; then
        # shellcheck disable=SC2088 # literal tilde, see above
        printf '%s\n' "~/.config/opencode/preamble.md"
    else
        dots_effective_preamble "$agents_dir/preamble.md"
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
