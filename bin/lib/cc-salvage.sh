# shellcheck shell=bash
# cc-salvage.sh — reopen Claude sessions that a restart or crash killed.
# Sourced by bin/cc-salvage after bin/lib/resume.sh. Functions only, so bats
# can source it. Bash 3.2 compatible (macOS /bin/bash).
#
# Source of truth: ~/.claude/sessions/<pid>.json, one record per Claude
# process (sessionId, cwd, procStart). A record is dead when its pid is gone
# or now belongs to a process with a different start time.

# salvage_duration_secs <dur> — "90m", "6h", "2d", or "30s" in seconds.
salvage_duration_secs() {
    [[ "$1" =~ ^([0-9]+)([smhd])$ ]] || return 1
    local n=$(( 10#${BASH_REMATCH[1]} ))
    case "${BASH_REMATCH[2]}" in
        s) echo "$n" ;;
        m) echo $(( n * 60 )) ;;
        h) echo $(( n * 3600 )) ;;
        d) echo $(( n * 86400 )) ;;
    esac
}

# salvage_pid_live <pid> <procStart> — exit 0 when the recorded process runs.
# Field 22 of /proc/<pid>/stat is the start time that Claude records as
# procStart. Without /proc (macOS), procStart is the `ps -o lstart=` text in
# UTC. A mismatch means a reboot gave the pid to another process. Compare
# with whitespace squeezed, because ps pads the day. A procStart of "-" has
# nothing to compare, so only kill -0 decides.
salvage_pid_live() {
    local pid="$1" want="$2" proc="${CC_SALVAGE_PROC_DIR:-/proc}" stat got
    local -a fields
    if [[ ! -d "$proc" ]]; then
        if [[ "$want" == - ]]; then
            kill -0 "$pid" 2>/dev/null
            return
        fi
        got="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
        read -r -a fields <<< "$got"
        got="${fields[*]}"
        read -r -a fields <<< "$want"
        [[ -n "$got" && "$got" == "${fields[*]}" ]]
        return
    fi
    [[ -r "$proc/$pid/stat" ]] || return 1
    stat="$(<"$proc/$pid/stat")"
    # The comm field can hold spaces; fields after ") " start at field 3.
    read -r -a fields <<< "${stat##*) }"
    [[ "$want" == - || "${fields[19]:-}" == "$want" ]]
}

# salvage_registry_rows — print one row per terminal or Remote Control
# session: "pid<TAB>procStart<TAB>sessionId<TAB>cwd<TAB>name<TAB>path".
# Remote Control spawns are sdk-cli records with a bridgeSessionId. Other
# sdk-cli records are headless runs, so the rows leave them out. "-" fills an
# empty procStart or name, because read with a tab IFS merges empty fields.
salvage_registry_rows() {
    local f
    for f in "$HOME"/.claude/sessions/*.json; do
        [[ -f "$f" ]] || continue
        jq -r --arg file "$f" 'select((.entrypoint == "cli" or (.entrypoint == "sdk-cli" and has("bridgeSessionId")))
                and (.kind // "interactive") == "interactive"
                and (.sessionId | type) == "string" and (.cwd | type) == "string")
            | [(.pid | tostring), (.procStart // "-" | tostring), .sessionId, .cwd,
               (if (.name // "") == "" then "-" else .name end), $file]
            | @tsv' "$f" 2>/dev/null || true
    done
}

# salvage_transcript <session-id> — path of the session's non-empty transcript.
salvage_transcript() {
    local f
    for f in "$HOME"/.claude/projects/*/"$1".jsonl; do
        [[ -s "$f" ]] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# salvage_candidates <since-epoch> <until-epoch> — dead sessions whose
# transcript changed inside the window, newest first, as
# "mtime<TAB>sessionId<TAB>cwd<TAB>name<TAB>pid<TAB>procStart<TAB>path".
# A session id with any live record is left out, because a resume would fork
# a second writer.
salvage_candidates() {
    local since="$1" until="$2" rows live=" " seen=" "
    local pid start sid cwd name file t mtime
    rows="$(salvage_registry_rows)"
    [[ -n "$rows" ]] || return 0
    while IFS=$'\t' read -r pid start sid _; do
        if salvage_pid_live "$pid" "$start"; then live+="$sid "; fi
    done <<< "$rows"
    while IFS=$'\t' read -r pid start sid cwd name file; do
        [[ "$sid" =~ ^[0-9A-Za-z_-]+$ ]] || continue
        [[ "$live$seen" == *" $sid "* ]] && continue
        seen+="$sid "
        t="$(salvage_transcript "$sid")" || continue
        mtime="$(resume_file_mtime "$t")" || continue
        if (( mtime >= since && mtime <= until )); then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mtime" "$sid" "$cwd" "$name" "$pid" "$start" "$file"
        fi
    done <<< "$rows" | sort -rn
}

# salvage_target_session <requested> — tmux session that receives the windows:
# the requested one, else the current one inside tmux, else "salvage".
# Creates a missing session detached.
salvage_target_session() {
    local s="$1"
    if [[ -z "$s" && -n "${TMUX:-}" ]]; then
        tmux display-message -p '#S'
        return
    fi
    s="${s:-salvage}"
    tmux has-session -t "=$s" 2>/dev/null || tmux new-session -d -s "$s"
    printf '%s\n' "$s"
}

# salvage_archive_record <file> <pid> <procStart> <session-id> — after a
# successful resume, move the selected record to salvaged/ when its pid,
# procStart, and sessionId still match. Also move every other dead record of
# the same session. A live record never moves. Each archive gets a unique
# <pid>.<sessionId>.<epoch>.json name, and mv -n never overwrites one.
salvage_archive_record() {
    local file="$1" pid="$2" start="$3" sid="$4" dest="$HOME/.claude/sessions/salvaged"
    local p s i f stamp
    stamp="$(date +%s)"
    if jq -e --arg pid "$pid" --arg start "$start" --arg sid "$sid" \
        '(.pid | tostring) == $pid and (.procStart // "-" | tostring) == $start and .sessionId == $sid' \
        "$file" >/dev/null 2>&1; then
        mkdir -p "$dest" && mv -n -- "$file" "$dest/$(basename "$file" .json).$sid.$stamp.json"
    fi
    while IFS=$'\t' read -r p s i _ _ f; do
        [[ "$i" == "$sid" && "$f" != "$file" ]] || continue
        salvage_pid_live "$p" "$s" || { mkdir -p "$dest" && mv -n -- "$f" "$dest/$(basename "$f" .json).$sid.$stamp.json"; }
    done < <(salvage_registry_rows)
    return 0
}

# salvage_launch <tmux-session> <row> — open a detached window that resumes
# the session of a candidate row with the same launcher as `cc`. After a
# successful resume the window archives the records. After a failed resume
# the window waits for Enter, so the error stays visible. tmux expands "#"
# in the window name and directory, so "##" escapes it. The window sources
# this file by path, because DOTFILES_DIR is not in its environment.
salvage_launch() {
    local target="$1" row="$2" dotfiles="${DOTFILES_DIR:-$HOME/Dev/dotfiles}"
    local sid cwd name pid start file
    IFS=$'\t' read -r _ sid cwd name pid start file <<< "$row"
    [[ "$name" == - ]] && name="${sid:0:8}"
    local -a cmd=(claude --resume "$sid")
    [[ -x "$dotfiles/bin/dotsclaude" ]] && cmd=(env CLAUDE_BIN=claude "$dotfiles/bin/dotsclaude" --resume "$sid")
    # shellcheck disable=SC2016 # Variables expand in the window's shell.
    tmux new-window -d -t "$target:" -n "${name//#/##}" -c "${cwd//#/##}" \
        bash -c '
            lib=$1 file=$2 pid=$3 start=$4 sid=$5
            shift 5
            "$@"; rc=$?
            if [ "$rc" -eq 0 ]; then
                . "$lib" && salvage_archive_record "$file" "$pid" "$start" "$sid"
            else
                echo "cc-salvage: resume exited $rc (Enter closes)"
                read -r _
            fi' \
        bash "${BASH_SOURCE[0]}" "$file" "$pid" "$start" "$sid" "${cmd[@]}"
}

salvage_usage() {
    cat <<'EOF'
Usage: cc-salvage [--since DUR] [--until DUR] [--session NAME] [--limit N] [--dry-run]

Reopen Claude sessions that died (box restart, crash) in tmux windows.
Each window runs `claude --resume <id>` in the session's original cwd.

  --since DUR     oldest last activity to include (default 24h)
  --until DUR     newest last activity to include (default 0s = now)
  --session NAME  tmux session for the windows (default: current, else "salvage")
  --limit N       resume at most N sessions, newest first (default 6;
                  bin/claude refuses past 8 running sessions)
  --dry-run       list the candidates; open no windows

DUR is <number><s|m|h|d>, counted back from now.
EOF
}

# salvage_resume_rows <session> <dry-run> <limit> <now> — read candidate rows
# on stdin, launch up to <limit> of them, and print one status line each.
salvage_resume_rows() {
    local session="$1" dry_run="$2" limit="$3" now="$4" target="" launched=0
    local row mtime sid cwd name status
    printf 'SESSION\tNAME\tAGE\tSTATUS\tCWD\n'
    while IFS= read -r row; do
        IFS=$'\t' read -r mtime sid cwd name _ <<< "$row"
        [[ "$name" == - ]] && name="${sid:0:8}"
        if [[ ! -d "$cwd" ]]; then
            status=skipped:cwd-missing
        elif (( launched >= limit )); then
            status=skipped:limit
        elif [[ "$dry_run" == true ]]; then
            status=dry-run
            launched=$(( launched + 1 ))
        else
            [[ -n "$target" ]] || target="$(salvage_target_session "$session")"
            if salvage_launch "$target" "$row"; then
                status=resumed
                launched=$(( launched + 1 ))
            else
                status=failed
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$sid" "$name" "$(resume_format_age "$now" "$mtime")" "$status" "$cwd"
    done
    [[ -z "$target" ]] || echo "cc-salvage: windows are in tmux session '$target'" >&2
}

# salvage_main [args] — parse, list candidates, and launch each one.
salvage_main() {
    local since=24h until=0s session="" limit=6 dry_run=false since_s until_s now rows
    while (($#)); do
        case "$1" in
            --since|--until|--session|--limit)
                (($# >= 2)) || { salvage_usage >&2; return 2; }
                printf -v "${1#--}" '%s' "$2"; shift 2 ;;
            --dry-run|-n) dry_run=true; shift ;;
            -h|--help) salvage_usage; return 0 ;;
            *) echo "cc-salvage: unknown argument: $1" >&2; salvage_usage >&2; return 2 ;;
        esac
    done
    since_s="$(salvage_duration_secs "$since")" || { echo "cc-salvage: bad --since duration: $since" >&2; return 2; }
    until_s="$(salvage_duration_secs "$until")" || { echo "cc-salvage: bad --until duration: $until" >&2; return 2; }
    [[ "$limit" =~ ^[0-9]+$ ]] || { echo "cc-salvage: --limit needs a number: $limit" >&2; return 2; }
    [[ "$session" != *[:.]* ]] || { echo "cc-salvage: --session cannot contain ':' or '.': $session" >&2; return 2; }
    command -v jq >/dev/null || { echo "cc-salvage: jq is required" >&2; return 1; }
    now="${CC_SALVAGE_NOW:-$(date +%s)}"
    rows="$(salvage_candidates $(( now - since_s )) $(( now - until_s )))"
    if [[ -z "$rows" ]]; then
        echo "cc-salvage: no dead sessions with activity in the window" >&2
        return 0
    fi
    salvage_resume_rows "$session" "$dry_run" $(( 10#$limit )) "$now" <<< "$rows"
}
