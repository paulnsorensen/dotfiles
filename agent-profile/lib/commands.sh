#!/usr/bin/env bash
# commands.sh — subcommand handlers for the `ap` CLI.
#
# Each function reads HARNESSES/TARGET/REMAINING from the env (parsed
# by `parse_common_opts` in `ap`) and the color globals from `ap` too.
# Sourced from `ap` after the renderer + lib files so cmd_install /
# cmd_uninstall can call into the *_render and *_clean entry points.

# shellcheck shell=bash

cmd_list() {
    local rows; rows=$(ap_list_profiles)
    [[ -z "$rows" ]] && { echo "(no profiles found in $PWD/.agent-profiles or $DOTFILES_DIR/profiles)"; return 0; }
    echo -e "${CYAN}Available profiles:${NC}"
    while IFS=$'\t' read -r name root; do
        local desc=""
        if [[ -f "$root/$name/profile.yaml" ]]; then
            desc=$(yq -r '.description // ""' "$root/$name/profile.yaml" 2>/dev/null || echo "")
        fi
        printf "  ${GREEN}%-20s${NC} %s\n" "$name" "$desc"
        printf "    ${BLUE}↳${NC} %s\n" "$root/$name"
    done <<<"$rows"
}

cmd_describe() {
    local name="$1"
    local dir; dir=$(ap_find_profile_dir "$name") \
        || { echo -e "${RED}ap: profile '$name' not found${NC}" >&2; exit 1; }
    local merged; merged=$(ap_parse_manifest "$dir")
    echo -e "${CYAN}Profile: $name${NC}  ${BLUE}($dir)${NC}"
    echo
    jq '{
        name, description,
        mcps:     [.mcps[].name],
        agents:   [.agents[].name],
        skills:   [.skills[].name],
        commands: [.commands[].name],
        hooks:    [.hooks[] | {event, matcher, harnesses: (.harnesses // ["claude"])}],
        permissions: (.settings.permissions_allow // [])
    }' <<<"$merged"
}

cmd_path() {
    local dir; dir=$(ap_find_profile_dir "$1") \
        || { echo -e "${RED}ap: profile '$1' not found${NC}" >&2; exit 1; }
    echo "$dir"
}

cmd_install() {
    local name="${REMAINING[0]:-}"
    [[ -n "$name" ]] || { echo -e "${RED}ap install: profile name required${NC}" >&2; exit 1; }

    local dir; dir=$(ap_find_profile_dir "$name") \
        || { echo -e "${RED}ap: profile '$name' not found${NC}" >&2; exit 1; }

    echo -e "${BLUE}→ Installing profile '$name' from $dir${NC}"
    echo -e "  target:   $TARGET"
    echo -e "  harness:  ${HARNESSES[*]}"

    local merged; merged=$(ap_parse_manifest "$dir")

    ap_manifest_init "$TARGET"

    # Accumulate new files across all harnesses so we can diff against the
    # prior install record and clear orphans before re-recording.
    local -a all_new_files=()
    local h; for h in "${HARNESSES[@]}"; do
        _AP_OUT_FILES=()
        echo -e "  ${CYAN}━━ $h ━━${NC}"
        case "$h" in
            claude)   claude_render   "$merged" "$TARGET" ;;
            codex)    codex_render    "$merged" "$TARGET" ;;
            opencode) opencode_render "$merged" "$TARGET" ;;
            cursor)   cursor_render   "$merged" "$TARGET" ;;
            copilot)  copilot_render  "$merged" "$TARGET" ;;
        esac
        local f
        for f in "${_AP_OUT_FILES[@]+"${_AP_OUT_FILES[@]}"}"; do
            all_new_files+=("$f")
        done
    done

    # Build a JSON array of new files (deduped). On a re-install, drop
    # any orphans (files in the old record but not in the new set) from
    # disk before overwriting the manifest's files list with the new one.
    # ap_manifest_diff_and_clean honours ref-counting so shared paths
    # claimed by other profiles stay on disk.
    local new_files_json
    if ((${#all_new_files[@]})); then
        new_files_json=$(printf '%s\n' "${all_new_files[@]}" | jq -R . | jq -sc 'unique')
    else
        new_files_json='[]'
    fi
    ap_manifest_diff_and_clean "$TARGET" "$name" "$new_files_json"

    # Replace this profile's files list atomically (rather than appending
    # via ap_manifest_record_file, which would keep stale entries). The
    # manifest already passed validation via ap_manifest_init.
    local mpath; mpath=$(ap_manifest_path "$TARGET")
    local mtmp; mtmp=$(mktemp)
    jq --arg p "$name" --argjson f "$new_files_json" '
        .[$p] = ((.[$p] // {}) | .files = $f)
    ' "$mpath" > "$mtmp" && mv "$mtmp" "$mpath"

    # Cache the resolved manifest so uninstall can pass it to *_clean
    # for surgical edits to merged files even if the profile dir gets
    # deleted from disk later.
    ap_manifest_record_merged_json "$TARGET" "$name" "$merged"

    echo -e "${GREEN}✓ Installed${NC}"
}

cmd_uninstall() {
    local name="${REMAINING[0]:-}"
    [[ -n "$name" ]] || { echo -e "${RED}ap uninstall: profile name required${NC}" >&2; exit 1; }

    echo -e "${BLUE}→ Uninstalling profile '$name' from $TARGET${NC}"

    # Uninstall always runs every harness's cleaner regardless of
    # --harness. The manifest records files globally (not per-harness),
    # so the rm pass below would orphan entries in shared/merged files
    # (e.g. opencode.json, .mcp.json, .claude/settings.local.json) if we
    # only ran a subset of cleaners. The renderers' *_clean functions
    # are surgical jq edits — running one whose harness didn't install
    # anything is a noop.
    HARNESSES=("${ALL_HARNESSES[@]}")

    # Prefer the cached merged_json from install-time so renderers can
    # surgically undo their merges. If it isn't there (manifest from an
    # older install, or hand-deleted), fall back to re-parsing the
    # profile dir if still on disk, else pass a stub by name.
    local merged=""
    merged=$(ap_manifest_merged_json "$TARGET" "$name")
    if [[ -z "$merged" ]]; then
        local dir
        if dir=$(ap_find_profile_dir "$name" 2>/dev/null); then
            merged=$(ap_parse_manifest "$dir")
        else
            merged=$(jq -n --arg n "$name" '{name: $n, mcps: [], settings: {}}')
        fi
    fi

    local h
    for h in "${HARNESSES[@]}"; do
        case "$h" in
            claude)   declare -F claude_clean   >/dev/null && claude_clean   "$merged" "$TARGET" ;;
            codex)    declare -F codex_clean    >/dev/null && codex_clean    "$merged" "$TARGET" ;;
            opencode) declare -F opencode_clean >/dev/null && opencode_clean "$merged" "$TARGET" ;;
            cursor)   declare -F cursor_clean   >/dev/null && cursor_clean   "$merged" "$TARGET" ;;
            copilot)  declare -F copilot_clean  >/dev/null && copilot_clean  "$merged" "$TARGET" ;;
        esac
    done

    # Delete every file we recorded — but keep paths still claimed by
    # another installed profile (shared `.mcp.json`, `opencode.json`,
    # cross-harness `.claude/agents/<n>.md`).
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ap_manifest_other_profiles_claim_file "$TARGET" "$name" "$f"; then
            echo -e "  ${BLUE}↳${NC} keeping $f (claimed by another profile)"
            continue
        fi
        local abs="$TARGET/$f"
        if [[ -e "$abs" || -L "$abs" ]]; then
            rm -rf -- "$abs"
        fi
    done < <(ap_manifest_files "$TARGET" "$name")

    ap_manifest_clear "$TARGET" "$name"
    echo -e "${GREEN}✓ Uninstalled${NC}"
}

cmd_launch() {
    local harness="${REMAINING[0]:-}"
    [[ -n "$harness" ]] || { echo -e "${RED}ap launch: harness required (claude|codex|opencode|cursor|copilot)${NC}" >&2; exit 1; }
    local name="${REMAINING[1]:-}"
    local -a passthrough=("${REMAINING[@]:2}")

    case "$harness" in
        claude|codex|opencode|cursor|copilot) ;;
        *) echo -e "${RED}ap launch: unknown harness '$harness'${NC}" >&2; exit 1 ;;
    esac

    if [[ -n "$name" ]]; then
        # Re-render before exec — cheap, idempotent, picks up any
        # edits to the profile dir since last launch.
        HARNESSES=("$harness")
        cmd_install
    fi

    echo -e "${BLUE}→ exec $harness ${passthrough[*]:-}${NC}"
    exec "$harness" "${passthrough[@]+"${passthrough[@]}"}"
}
