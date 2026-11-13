# shellcheck shell=bash
# alfred.sh — Alfred workflow helpers, sourced by bin/alfred-wt.
#
# Alfred runs workflow scripts with a minimal PATH and without the zsh config,
# so these helpers use plain bash, `open`, and absolute fallbacks only. They
# need no jq. Functions only; sourcing has no side effects.
#
# Requires bin/lib/worktree.sh (wt_find) to be sourced first.

# Escape stdin for JSON string content: backslash and double quote. Paths and
# branch names hold no control characters. sed, not ${var//}, because Alfred
# runs /bin/bash 3.2 and bash 5.2 treats `&` in a replacement as the match.
alfred_json_escape() {
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Print `path<TAB>branch (age)` rows for T3 Code worktrees under $1
# (<root>/<repo>/<id>), the same row shape as wt_find.
alfred_t3_worktree_rows() {
    local root="$1" child branch last_rel
    [[ -d "$root" ]] || return 0
    for child in "$root"/*/*/; do
        [[ -e "${child}.git" ]] || continue
        child="${child%/}"
        branch="$(git -C "$child" symbolic-ref --short --quiet HEAD 2>/dev/null || echo '(detached)')"
        last_rel="$(git -C "$child" log -1 --format='%cr' 2>/dev/null || echo 'unknown')"
        printf '%s\t%s (%s)\n' "$child" "$branch" "$last_rel"
    done
}

# Print one Alfred script-filter item for a JSON-escaped
# `path<TAB>branch (age)` row. Enter runs the terminal action, Cmd opens Zed,
# and Option copies the path.
alfred_wt_item() {
    local row="$1" path status repo slug display
    path="${row%%$'\t'*}"
    status="${row#*$'\t'}"
    slug="${path##*/}"
    repo="${path%/*}"
    [[ "${repo##*/}" == .worktrees ]] && repo="${repo%/*}"
    repo="${repo##*/}"
    display="$path"
    # shellcheck disable=SC2088 # The subtitle shows a literal ~, not a path.
    [[ "$path" == "$HOME"/* ]] && display="~/${path#"$HOME"/}"

    printf '{"uid":"%s","title":"%s/%s","subtitle":"%s · %s","arg":"%s",' \
        "$path" "$repo" "$slug" "$status" "$display" "$path"
    printf '"match":"%s %s %s","text":{"copy":"%s"},' "$repo" "$slug" "${status% (*}" "$path"
    printf '"variables":{"wt_action":"terminal"},"mods":{'
    printf '"cmd":{"arg":"%s","subtitle":"Open in Zed","variables":{"wt_action":"zed"}},' "$path"
    printf '"alt":{"arg":"%s","subtitle":"Copy path","variables":{"wt_action":"copy"}}}}' "$path"
}

# Print the script-filter JSON for every worktree under the Dev root ($1) and
# the T3 root ($2). Alfred filters the items against the `match` field.
# A scan of ~400 worktrees takes seconds, so Alfred (5.5+) caches the result
# and shows the cached list at once while it reloads in the background.
alfred_wt_list() {
    local dev_root="$1" t3_root="$2" row sep="" count=0 roots
    printf '{"cache":{"seconds":300,"loosereload":true},"items":['
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        printf '%s' "$sep"
        alfred_wt_item "$row"
        sep=","
        count=$((count + 1))
    done < <({ wt_find --root "$dev_root"; alfred_t3_worktree_rows "$t3_root"; } | alfred_json_escape)
    if (( count == 0 )); then
        roots="$(printf '%s and %s' "$dev_root" "$t3_root" | alfred_json_escape)"
        printf '{"title":"No worktrees found","subtitle":"Searched %s","valid":false}' "$roots"
    fi
    printf ']}\n'
}

# Run one worktree action. `terminal` opens Ghostty on `alfred-wt session`,
# which starts the cc tmux session; it falls back to Terminal.app at the path.
alfred_wt_open() {
    local action="$1" path="$2" self="$3"
    if [[ ! -d "$path" ]]; then
        echo "alfred-wt: not a directory: $path" >&2
        return 1
    fi
    case "$action" in
        terminal)
            open -na Ghostty --args -e "$self" session "$path" 2>/dev/null ||
                open -a Terminal "$path"
            ;;
        zed) open -a Zed "$path" ;;
        copy) printf '%s' "$path" | pbcopy ;;
        *)
            echo "alfred-wt: unknown action: $action (terminal|zed|copy)" >&2
            return 2
            ;;
    esac
}

# Package the workflow source dir ($1) into the .alfredworkflow file $3.
# Replaces each __DOTFILES_DIR__ token in info.plist with the XML-escaped $2.
# awk index/substr, not gsub or ${var//}, keeps `&` in the path literal.
alfred_package_workflow() {
    local src="$1" dotfiles_dir="$2" out="$3" stage
    if [[ ! -f "$src/info.plist" ]]; then
        echo "alfred-wt: no info.plist in $src" >&2
        return 1
    fi
    out="$(cd "$(dirname "$out")" && pwd)/${out##*/}"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/alfred-workflow.XXXXXX")"
    cp -R "$src"/. "$stage"/
    ALFRED_REPLACEMENT="$(printf '%s' "$dotfiles_dir" |
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')" \
        awk 'BEGIN { tok = "__DOTFILES_DIR__"; rep = ENVIRON["ALFRED_REPLACEMENT"] }
            { out = ""
              while ((i = index($0, tok)) > 0) {
                  out = out substr($0, 1, i - 1) rep
                  $0 = substr($0, i + length(tok))
              }
              print out $0 }' "$src/info.plist" > "$stage/info.plist"
    rm -f "$out"
    (cd "$stage" && zip -qr "$out" .) || { rm -rf "$stage"; return 1; }
    rm -rf "$stage"
}
