# shellcheck shell=bash
# resume.sh — post-reboot tmux resume helpers, sourced by bin/dots.
#
# Parallels the .sync <-> .sync-lib.sh "lib beside script" precedent (see
# bin/lib/worktree.sh). Functions only — no top-level side effects, so
# sourcing is safe from bats tests.

# resume_encode_claude_dir <cwd> — mirror the `~/.claude/projects/<encoded>`
# naming: every "/" (including the leading one) AND every "." becomes "-".
# e.g. /home/paul/Dev/dotfiles -> -home-paul-Dev-dotfiles;
# /home/paul/Dev/dotfiles/.worktrees/oclp -> -home-paul-Dev-dotfiles--worktrees-oclp.
resume_encode_claude_dir() {
    local cwd="$1"
    echo "${cwd//[.\/]/-}"
}

# resume_file_mtime <path> — portable epoch mtime. GNU stat uses `-c %Y`;
# BSD/macOS stat uses `-f %m`.
resume_file_mtime() {
    local file="$1"
    stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null
}

# resume_claude_session <cwd> — newest *.jsonl under the matching claude
# project dir. Prints "<session-id>\t<mtime-epoch>"; returns 1 on no match.
resume_claude_session() {
    local cwd="$1" dir file newest="" newest_mtime=0 mtime
    dir="$HOME/.claude/projects/$(resume_encode_claude_dir "$cwd")"
    [[ -d "$dir" ]] || return 1
    for file in "$dir"/*.jsonl; do
        [[ -f "$file" ]] || continue
        mtime=$(resume_file_mtime "$file") || continue
        if (( mtime > newest_mtime )); then
            newest_mtime=$mtime
            newest="$file"
        fi
    done
    [[ -n "$newest" ]] || return 1
    printf '%s\t%s\n' "$(basename "$newest" .jsonl)" "$newest_mtime"
}

# resume_codex_session <cwd> — newest rollout file (last 7 days) whose
# session_meta.payload.cwd matches. Prints "<session-id>\t<mtime-epoch>";
# returns 1 on no match. RESUME_CODEX_SESSIONS_DIR overrides the scan root
# for tests.
resume_codex_session() {
    local cwd="$1" root="${RESUME_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
    [[ -d "$root" ]] || return 1
    local mtime file file_cwd file_id best_id="" best_mtime=-1
    while IFS= read -r -d '' file; do
        mtime=$(resume_file_mtime "$file") || continue
        file_cwd=$(head -1 "$file" | jq -r '.payload.cwd // empty' 2>/dev/null) || continue
        [[ "$file_cwd" == "$cwd" ]] || continue
        file_id=$(head -1 "$file" | jq -r '.payload.id // empty' 2>/dev/null) || true
        [[ -n "$file_id" ]] || continue
        if (( mtime > best_mtime )); then
            best_mtime=$mtime
            best_id=$file_id
        fi
    done < <(find "$root" -name 'rollout-*.jsonl' -mtime -7 -print0 2>/dev/null)
    [[ -n "$best_id" ]] || return 1
    printf '%s\t%s\n' "$best_id" "$best_mtime"
}

# resume_opencode_session <cwd> — newest session row whose directory matches.
# Prints "<session-id>\t<updated-epoch-seconds>"; returns 1 on no match.
# RESUME_OPENCODE_DB overrides the db path for tests.
resume_opencode_session() {
    local cwd="$1" db="${RESUME_OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
    [[ -f "$db" ]] || return 1
    local escaped row id ms
    escaped=${cwd//\'/\'\'}
    row=$(sqlite3 -readonly "$db" \
        "SELECT id, time_updated FROM session WHERE directory = '$escaped' ORDER BY time_updated DESC LIMIT 1;" \
        2>/dev/null) || true
    [[ -n "$row" ]] || return 1
    id="${row%%|*}"
    ms="${row##*|}"
    printf '%s\t%s\n' "$id" "$((ms / 1000))"
}

# resume_resurrect_dir — mirror tmux-resurrect's own default resolution
# (scripts/helpers.sh): ~/.tmux/resurrect if present, else the XDG data dir.
# No @resurrect-dir override is set in tmux.conf.
resume_resurrect_dir() {
    if [[ -d "$HOME/.tmux/resurrect" ]]; then
        echo "$HOME/.tmux/resurrect"
    else
        echo "${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
    fi
}

# resume_needs_restore [session] — exit 0 when a restore should run: no tmux
# server at all, or (when a session name is given) that session is missing.
resume_needs_restore() {
    local session="${1:-}"
    if [[ -n "$session" ]]; then
        tmux has-session -t "$session" 2>/dev/null && return 1
        return 0
    fi
    tmux list-sessions >/dev/null 2>&1 && return 1
    return 0
}

# resume_restore_snapshot <dotfiles_dir> — start a detached server if none is
# running (tmux-resurrect's restore.sh needs a live server to query options
# and create sessions against), then run the vendored restore script.
# No-ops (returns 1) when there's no saved snapshot to restore.
resume_restore_snapshot() {
    local dotfiles_dir="$1" resurrect_dir restore_script
    resurrect_dir="$(resume_resurrect_dir)"
    [[ -f "$resurrect_dir/last" ]] || return 1
    restore_script="$dotfiles_dir/tmux/plugins/tmux-resurrect/scripts/restore.sh"
    [[ -f "$restore_script" ]] || return 1
    tmux list-sessions >/dev/null 2>&1 || tmux new-session -d
    bash "$restore_script"
}

# resume_list_panes — tab-separated session/window/pane/pane_id/cwd, one
# pane per line.
resume_list_panes() {
    tmux list-panes -a -F '#{session_name}	#{window_index}	#{pane_index}	#{pane_id}	#{pane_current_path}'
}

# resume_format_age <now-epoch> <then-epoch> — compact age like "2d3h",
# "1h5m", or "12m".
resume_format_age() {
    local now="$1" then="$2" diff days hours mins
    diff=$(( now - then ))
    (( diff < 0 )) && diff=0
    days=$(( diff / 86400 ))
    hours=$(( (diff % 86400) / 3600 ))
    mins=$(( (diff % 3600) / 60 ))
    if (( days > 0 )); then
        printf '%dd%dh' "$days" "$hours"
    elif (( hours > 0 )); then
        printf '%dh%dm' "$hours" "$mins"
    else
        printf '%dm' "$mins"
    fi
}

# resume_best_match <cwd> — the newest session across all three harnesses.
# Prints "<harness>\t<session-id>\t<epoch>"; returns 1 when none match.
resume_best_match() {
    local cwd="$1" line id epoch
    local best_harness="" best_id="" best_epoch=-1

    if line=$(resume_claude_session "$cwd"); then
        id="${line%%$'\t'*}"; epoch="${line##*$'\t'}"
        if (( epoch > best_epoch )); then best_epoch=$epoch; best_id=$id; best_harness="claude"; fi
    fi
    if line=$(resume_codex_session "$cwd"); then
        id="${line%%$'\t'*}"; epoch="${line##*$'\t'}"
        if (( epoch > best_epoch )); then best_epoch=$epoch; best_id=$id; best_harness="codex"; fi
    fi
    if line=$(resume_opencode_session "$cwd"); then
        id="${line%%$'\t'*}"; epoch="${line##*$'\t'}"
        if (( epoch > best_epoch )); then best_epoch=$epoch; best_id=$id; best_harness="opencode"; fi
    fi

    [[ -n "$best_harness" ]] || return 1
    printf '%s\t%s\t%s\n' "$best_harness" "$best_id" "$best_epoch"
}

# resume_command_for <harness> <session-id> — the exact resume command to
# type into the pane.
resume_command_for() {
    local harness="$1" id="$2"
    case "$harness" in
        claude) printf 'claude --resume %s' "$id" ;;
        codex) printf 'codex resume %s' "$id" ;;
        opencode) printf 'opencode --session %s' "$id" ;;
    esac
}

# resume_parse_args [--dry-run] [--session <name>] — prints
# "<dry-run>\t<session>".
resume_parse_args() {
    local dry_run=false session=""
    while (($#)); do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --session) session="${2:?--session requires a value}"; shift 2 ;;
            *)
                echo "resume: unknown argument: $1" >&2
                return 1
                ;;
        esac
    done
    printf '%s\t%s\n' "$dry_run" "$session"
}

resume_resume_panes() {
    local dry_run="$1" now="$2"
    local _ pane_id cwd match harness rest id epoch age
    printf 'PANE\tCWD\tHARNESS\tSESSION\tAGE\n'
    while IFS=$'\t' read -r _ _ _ pane_id cwd; do
        [[ -n "$pane_id" ]] || continue
        match=$(resume_best_match "$cwd") || continue
        harness="${match%%$'\t'*}"
        rest="${match#*$'\t'}"
        id="${rest%%$'\t'*}"
        epoch="${rest##*$'\t'}"
        age="$(resume_format_age "$now" "$epoch")"
        printf '%s\t%s\t%s\t%s\t%s\n' "$pane_id" "$cwd" "$harness" "$id" "$age"
        [[ "$dry_run" == true ]] || tmux send-keys -t "$pane_id" "$(resume_command_for "$harness" "$id")"
    done < <(resume_list_panes)
}


# resume_main [--dry-run] [--session <name>] — orchestrates the full flow:
# restore the snapshot if needed, enumerate panes, print the summary table,
# and (unless --dry-run) type the resume command into each matched pane.
resume_main() {
    local parsed dry_run session dotfiles_dir
    parsed=$(resume_parse_args "$@") || return
    dry_run="${parsed%%$'\t'*}"
    session="${parsed#*$'\t'}"
    dotfiles_dir="${DOTFILES_DIR:-$HOME/Dev/dotfiles}"

    if resume_needs_restore "$session"; then
        resume_restore_snapshot "$dotfiles_dir" || true
    fi

    resume_resume_panes "$dry_run" "$(date +%s)"
}
