# shellcheck shell=bash
# agy-wrapper.sh — ACP profile setup for bin/dotsagy/agy.
#
# T3 Code launches Antigravity as:
#   <binaryPath> acp --gemini-dir <profile> --app-data-dir antigravity-acp
# Before each spawn, T3 overwrites <profile>/antigravity-acp/settings.json with
# auth/gcp keys only and links only skills, ~/.gemini/AGENTS.md, GEMINI.md, and
# config/skills.json into <profile>. This library bridges the missing managed
# config into the isolated profile before exec'ing the mise agy binary:
#   - merges enableTerminalSandbox and permissions (adding mcp(t3-code/*)) from
#     ~/.gemini/antigravity-cli/settings.json while preserving T3's auth/gcp
#   - links config/mcp_config.json, config/plugins, and config/AGENTS.md
#
# ACP uses stdout for JSON-RPC, so functions in this file must never write to
# stdout; warnings go to stderr only. Functions only — no top-level side
# effects, so sourcing is safe from bats tests. Bash 3.2 compatible (macOS
# /bin/bash).

# _dots_agy_strip_trailing_slashes <path>
# Print <path> with all trailing slashes removed. Returns empty string for "/"
# or "//" so callers can reject root targets cleanly.
_dots_agy_strip_trailing_slashes() {
    local p="$1"
    while [[ "$p" == */ ]]; do
        p="${p%/}"
    done
    printf '%s\n' "$p"
}

# _dots_agy_realpath <path>
# Print the physical path of an existing directory, or resolve the parent
# directory for a file/non-existent leaf (without dereferencing a leaf file
# symlink).
_dots_agy_realpath() {
    local target="$1" dir base
    if [[ -d "$target" ]]; then
        (CDPATH='' cd -P -- "$target" >/dev/null 2>&1 && pwd) || printf '%s\n' "$target"
        return 0
    fi
    dir="$(dirname -- "$target")"
    base="$(basename -- "$target")"
    if [[ -d "$dir" ]]; then
        dir="$(CDPATH='' cd -P -- "$dir" >/dev/null 2>&1 && pwd)" || return 1
        printf '%s/%s\n' "${dir%/}" "$base"
    else
        printf '%s\n' "$target"
    fi
}

# _dots_agy_jq_bin
# Locate jq on PATH, falling back to the mise shim under bare service PATHs.
_dots_agy_jq_bin() {
    local shim="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims/jq"
    if [[ -n "${JQ_BIN:-}" ]]; then
        [[ -x "$JQ_BIN" ]] || return 1
        printf '%s\n' "$JQ_BIN"
        return 0
    fi
    if command -v jq >/dev/null 2>&1; then
        command -v jq
        return 0
    fi
    if [[ -x "$shim" ]]; then
        printf '%s\n' "$shim"
        return 0
    fi
    return 1
}

# dots_agy_parse_acp_args <argv...>
# When argv invokes `acp` with a gemini profile directory (via --gemini-dir /
# --gemini_dir or GEMINI_HOME), sets DOTS_AGY_PROFILE_DIR and
# DOTS_AGY_APP_DATA_DIR and returns 0. Returns 1 for non-acp calls or when no
# profile directory is specified.
dots_agy_parse_acp_args() {
    local val
    DOTS_AGY_PROFILE_DIR=""
    DOTS_AGY_APP_DATA_DIR="antigravity-cli"
    [[ "${1:-}" == "acp" ]] || return 1
    shift

    while (( $# > 0 )); do
        case "$1" in
            --gemini-dir|--gemini_dir)
                if (( $# >= 2 )) && [[ "$2" != -* ]]; then
                    DOTS_AGY_PROFILE_DIR="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --gemini-dir=*|--gemini_dir=*)
                DOTS_AGY_PROFILE_DIR="${1#*=}"
                shift
                ;;
            --app-data-dir|--app_data_dir)
                if (( $# >= 2 )) && [[ "$2" != -* ]]; then
                    if [[ -n "$2" ]]; then
                        DOTS_AGY_APP_DATA_DIR="$2"
                    fi
                    shift 2
                else
                    shift
                fi
                ;;
            --app-data-dir=*|--app_data_dir=*)
                val="${1#*=}"
                if [[ -n "$val" ]]; then
                    DOTS_AGY_APP_DATA_DIR="$val"
                fi
                shift
                ;;
            --)
                break
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ -z "$DOTS_AGY_PROFILE_DIR" && -n "${GEMINI_HOME:-}" ]]; then
        DOTS_AGY_PROFILE_DIR="$GEMINI_HOME"
    fi
    [[ -n "$DOTS_AGY_PROFILE_DIR" ]] || return 1
}

# dots_agy_link_file <src> <dst>
# Atomically symlink <dst> to <src> when <src> exists as a regular file.
# Replaces a missing target, an existing symlink, or a 0-byte regular file
# (agy seeds an empty mcp_config.json on first boot). Leaves non-empty regular
# files and directories untouched. Removes a stale symlink pointing at <src>
# if <src> is gone.
dots_agy_link_file() {
    local src="$1" dst="$2" real_src real_dst cur dst_dir base tmp
    if [[ "$src" != /* ]]; then
        src="$(_dots_agy_realpath "$src")" || src="$1"
    fi
    if [[ ! -f "$src" ]]; then
        if [[ -L "$dst" ]]; then
            cur="$(readlink "$dst" 2>/dev/null || true)"
            if [[ "$cur" == "$src" ]]; then
                rm -f -- "$dst"
            fi
        fi
        return 0
    fi
    real_src="$(_dots_agy_realpath "$src")" || real_src="$src"
    real_dst="$(_dots_agy_realpath "$dst")" || real_dst="$dst"
    [[ "$real_src" != "$real_dst" ]] || return 0

    if [[ -L "$dst" ]]; then
        cur="$(readlink "$dst" 2>/dev/null || true)"
        [[ "$cur" == "$src" ]] && return 0
    elif [[ -d "$dst" ]]; then
        return 0
    elif [[ -e "$dst" ]]; then
        # Replace only empty regular files (such as agy's 0-byte mcp_config.json).
        [[ -f "$dst" && ! -s "$dst" ]] || return 0
    fi

    dst_dir="$(dirname -- "$dst")"
    base="$(basename -- "$dst")"
    mkdir -p -- "$dst_dir"
    tmp="$dst_dir/.$base.$$.$RANDOM"
    rm -f -- "$tmp"
    if ln -s -- "$src" "$tmp" 2>/dev/null && mv -f -- "$tmp" "$dst" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$tmp"
    # Concurrent launcher may have already installed the target link.
    if [[ -L "$dst" && "$(readlink "$dst" 2>/dev/null || true)" == "$src" ]]; then
        return 0
    fi
    echo "dotsagy: failed to link $dst -> $src" >&2
    return 0
}

# dots_agy_link_dir <src> <dst>
# Symlink <dst> to <src> when <src> exists as a directory. Replaces a missing
# target, an existing symlink, or an empty directory. Leaves non-empty
# directories and regular files untouched. Removes a stale symlink to <src>
# when <src> is gone.
dots_agy_link_dir() {
    local src="$1" dst="$2" real_src real_dst cur
    if [[ "$src" != /* ]]; then
        src="$(_dots_agy_realpath "$src")" || src="$1"
    fi
    if [[ ! -d "$src" ]]; then
        if [[ -L "$dst" ]]; then
            cur="$(readlink "$dst" 2>/dev/null || true)"
            if [[ "$cur" == "$src" ]]; then
                rm -f -- "$dst"
            fi
        fi
        return 0
    fi
    real_src="$(_dots_agy_realpath "$src")" || real_src="$src"
    real_dst="$(_dots_agy_realpath "$dst")" || real_dst="$dst"
    [[ "$real_src" != "$real_dst" ]] || return 0

    if [[ -L "$dst" ]]; then
        cur="$(readlink "$dst" 2>/dev/null || true)"
        [[ "$cur" == "$src" ]] && return 0
    elif [[ -d "$dst" ]]; then
        rmdir -- "$dst" 2>/dev/null || return 0
    elif [[ -e "$dst" ]]; then
        return 0
    fi

    mkdir -p -- "$(dirname -- "$dst")"
    if ln -sfn -- "$src" "$dst" 2>/dev/null; then
        return 0
    fi
    # Concurrent launcher may have already installed the target link.
    if [[ -L "$dst" && "$(readlink "$dst" 2>/dev/null || true)" == "$src" ]]; then
        return 0
    fi
    echo "dotsagy: failed to link $dst -> $src" >&2
    return 0
}

# dots_agy_merge_settings <user-settings> <profile-settings>
# Merge managed enableTerminalSandbox and permissions (ensuring mcp(t3-code/*)
# in permissions.allow) from <user-settings> into <profile-settings>, keeping
# T3-owned keys such as auth and gcp intact. Intentionally skips toolPermission
# so T3's approval-required mode still prompts for review.
#
# Note: in agy 1.5.18, ACP's server.loadSettings reads enableTerminalSandbox
# while ignoring permissions.{allow,ask,deny} (T3 auto-allows t3-code/* MCP
# calls in auto and auto-accept-edits modes). Merging permissions keeps the
# profile ready as soon as agy ACP honors permission rules.
dots_agy_merge_settings() {
    local user_settings="$1" profile_settings="$2"
    local real_src real_dst jq_bin existing merged tmp profile_dir

    [[ -f "$user_settings" ]] || return 0
    [[ ! -d "$profile_settings" ]] || return 0
    real_src="$(_dots_agy_realpath "$user_settings")" || real_src="$user_settings"
    real_dst="$(_dots_agy_realpath "$profile_settings")" || real_dst="$profile_settings"
    [[ "$real_src" != "$real_dst" ]] || return 0

    if ! jq_bin="$(_dots_agy_jq_bin)"; then
        echo "dotsagy: jq missing; profile settings left unchanged" >&2
        return 0
    fi

    if ! "$jq_bin" -se 'length == 1 and (.[0] | type == "object")' -- "$user_settings" >/dev/null 2>&1; then
        echo "dotsagy: $user_settings is not a JSON object; profile settings left unchanged" >&2
        return 0
    fi

    if [[ -f "$profile_settings" && -n "$(tr -d '[:space:]' < "$profile_settings" 2>/dev/null)" ]]; then
        if ! "$jq_bin" -se 'length == 1 and (.[0] | type == "object")' -- "$profile_settings" >/dev/null 2>&1; then
            echo "dotsagy: $profile_settings is not a JSON object; left unchanged" >&2
            return 0
        fi
        existing="$(cat -- "$profile_settings")"
    else
        existing='{}'
    fi

    # shellcheck disable=SC2016 # jq variables inside single-quoted filter
    if ! merged=$(printf '%s\n' "$existing" | "$jq_bin" --slurpfile src "$user_settings" '
        ($src[0]) as $u
        | . as $base
        | (if ($u | has("enableTerminalSandbox")) and (($u.enableTerminalSandbox | type) == "boolean")
               and (($base.enableTerminalSandbox | type) != "boolean")
           then .enableTerminalSandbox = $u.enableTerminalSandbox
           else . end)
        | (if ($u | has("permissions")) and (($u.permissions | type) == "object")
           then .permissions = (
               $u.permissions
               | .allow = (
                   ((.allow // []) | if type == "array" then . else [] end)
                   | if any(. == "mcp(t3-code/*)") then . else . + ["mcp(t3-code/*)"] end
               )
           )
           else . end)
    ' 2>/dev/null); then
        echo "dotsagy: failed to merge profile settings; left unchanged" >&2
        return 0
    fi

    profile_dir="$(dirname -- "$profile_settings")"
    mkdir -p -- "$profile_dir"
    tmp="$(umask 077 && mktemp "$profile_dir/.settings.json.XXXXXX")" || {
        echo "dotsagy: failed to create temp file in $profile_dir" >&2
        return 0
    }
    if printf '%s\n' "$merged" > "$tmp" && mv -f -- "$tmp" "$profile_settings"; then
        return 0
    fi
    rm -f -- "$tmp"
    echo "dotsagy: failed to write $profile_settings" >&2
    return 0
}

# dots_agy_prepare_acp <user-gemini-dir> <argv...>
# Prepare an isolated ACP profile directory before exec'ing agy. No-op for
# non-acp commands or when the profile directory equals <user-gemini-dir>.
dots_agy_prepare_acp() {
    local user_gemini real_user real_profile app_dir profile_dir raw_app
    user_gemini="$(_dots_agy_strip_trailing_slashes "${1:-}")"; shift
    [[ -n "$user_gemini" ]] || return 0

    dots_agy_parse_acp_args ${1+"$@"} || return 0
    profile_dir="$(_dots_agy_strip_trailing_slashes "$DOTS_AGY_PROFILE_DIR")"
    [[ -n "$profile_dir" ]] || return 0

    real_user="$(_dots_agy_realpath "$user_gemini")" || real_user="$user_gemini"
    real_profile="$(_dots_agy_realpath "$profile_dir")" || real_profile="$profile_dir"
    [[ "$real_profile" != "$real_user" ]] || return 0

    raw_app="$(_dots_agy_strip_trailing_slashes "$DOTS_AGY_APP_DATA_DIR")"
    if [[ "$DOTS_AGY_APP_DATA_DIR" == /* ]]; then
        app_dir="$raw_app"
    elif [[ -n "$raw_app" ]]; then
        app_dir="$profile_dir/$raw_app"
    else
        app_dir=""
    fi

    dots_agy_link_file "$user_gemini/config/mcp_config.json" "$profile_dir/config/mcp_config.json"
    dots_agy_link_dir "$user_gemini/config/plugins" "$profile_dir/config/plugins"
    dots_agy_link_file "$user_gemini/config/AGENTS.md" "$profile_dir/config/AGENTS.md"
    if [[ -n "$app_dir" ]]; then
        dots_agy_merge_settings "$user_gemini/antigravity-cli/settings.json" "$app_dir/settings.json"
    fi
}
