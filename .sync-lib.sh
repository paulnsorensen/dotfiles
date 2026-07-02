#!/bin/bash
# Shared sync helpers sourced by .sync.
# Logging, skip-list dispatch, per-entry sync, and bootstrap installers.
#
# Variables provided by the sourcing script: dir, olddir
# shellcheck disable=SC2154

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Directory names that are never symlinked or dispatched to.
# Documented in the wiki (operations/sync-and-chezmoi.md) — keep in sync.
# `cursor` is skipped like `codex`: ~/.cursor is a real dir owned by chezmoi's
# install-cursor-plugin.sh + the ap cursor renderer, NOT a symlink to this repo
# (a whole-dir symlink leaked all of Cursor's runtime state back into dotfiles).
SYNC_SKIP_LIST=(".git" ".local" ".worktrees" "reference" "packages" "brew" "apt" "agents" "agent-profile" "codex" "cursor")

# Failure ledger — every .sync script that exits non-zero appends its name
# here. .sync inspects this at the end of run_sync, prints a
# summary, and exits non-zero so a partial sync doesn't masquerade as green.
SYNC_FAILURES=()

is_skipped() {
    local name="$1"
    local skip
    for skip in "${SYNC_SKIP_LIST[@]}"; do
        [[ "$name" == "$skip" ]] && return 0
    done
    return 1
}

# Parse run_sync arguments into exported env vars
parse_sync_args() {
    export DOTFILES_DEV=false

    while (( $# )); do
      case $1 in
         dev)
              echo "Setting dev=true"
              export DOTFILES_DEV=true
              ;;
         refresh|r)
              echo "Setting force_packages=true"
              export FORCE_PACKAGES=true
              ;;
      esac
      shift
    done
}

# Upgrade uv-managed tools
upgrade_uv_tools() {
    command -v uv &>/dev/null || return 0
    log_info "Upgrading uv-managed tools..."
    uv tool upgrade --all 2>&1 | while read -r line; do
      log_info "  $line"
    done
}

# Symlink a single file/dir, or dispatch to its .sync script if present
sync_entry() {
    local file="$1"

    is_skipped "$file" && return 0

    # Directories with .sync scripts manage their own setup (e.g. claude/.sync
    # symlinks items INTO ~/.claude without replacing the whole directory)
    if [[ -d "$dir/$file" && -f "$dir/$file/.sync" ]]; then
        log_info "Running .sync for $file."
        if ! bash "$dir/$file/.sync"; then
            log_error "sync for $file FAILED (continuing — will report at end)"
            SYNC_FAILURES+=("$file")
        fi
        return 0
    fi

    if [[ -h ~/."$file" ]]; then
        log_info "Removing old link to $file"
        rm ~/."$file"
    fi
    if [[ -f ~/."$file" || -d ~/."$file" ]]; then
        log_info "Moving existing $file from ~ to $olddir"
        rm -rf "$olddir/.$file" 2>/dev/null || true
        mv ~/."$file" "$olddir"
    fi

    log_info "Creating symlink to $file in home directory."
    ln -s "$dir/$file" ~/."$file"
}

# Dispatch hidden directories that own a .sync script (e.g. .copilot/).
# Globbing skips hidden dirs by default, so we iterate them explicitly.
sync_hidden_dirs() {
    local entry name
    for entry in "$dir"/.*/; do
        [[ -d "$entry" ]] || continue
        name="$(basename "$entry")"
        [[ "$name" == "." || "$name" == ".." ]] && continue
        is_skipped "$name" && continue
        [[ -f "$entry.sync" ]] || continue

        log_info "Running .sync for $name."
        if ! bash "$entry.sync"; then
            log_error "sync for $name FAILED (continuing — will report at end)"
            SYNC_FAILURES+=("$name")
        fi
    done
}

# Install TPM (tmux plugin manager) + its plugins if not present
install_tpm() {
    command -v tmux &>/dev/null || return 0
    [[ -d "$HOME/.tmux/plugins/tpm" ]] && return 0

    log_info "Installing TPM (tmux plugin manager)..."
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" 2>&1 | while read -r line; do
      log_info "  $line"
    done
    log_info "Installing tmux plugins..."
    "$HOME/.tmux/plugins/tpm/bin/install_plugins" 2>&1 | while read -r line; do
      log_info "  $line"
    done
}

# ── claude chezmoi source assembly ──────────────────────────────────────────
# sync_claude_chezmoi_sources <dotfiles_root> [<chezmoi_source_dir>]
#
# Assembles the registry-selected ~/.claude file payload into chezmoi source
# state as exact_ directories, so `chezmoi apply` DELETES anything live that
# is no longer selected (spec: chezmoi-authoritative-claude, decisions D1/G1).
#
#   dot_claude/exact_skills     ← skills/<name> per claude.yaml `skills`
#                                 + vendored external skills (skills/_registry.yaml)
#   dot_claude/exact_agents     ← agents/agent_definitions/<name>.md per
#                                 claude.yaml `agents`, frontmatter rendered
#                                 from agents/registry.yaml metadata
#   dot_claude/exact_commands   ← claude/commands
#   dot_claude/exact_hooks      ← claude/hooks + agents/hooks/*.sh
#   dot_claude/exact_lib        ← agents/lib
#   dot_claude/exact_reference  ← claude/reference + agents/reference
#   dot_claude/exact_workflows  ← claude/workflows
#
# The assembled trees are DERIVED state (gitignored); the repo dirs stay the
# single source of truth. Runs inside `dots sync` before `chezmoi apply`.

# Encode one path component for chezmoi source state.
#   _cz_encode_name <name> <is_dir> <is_executable>
_cz_encode_name() {
    local name="$1" is_dir="$2" is_exec="$3" prefix=""
    [[ "$is_dir" == true ]] && prefix+="exact_"
    [[ "$is_dir" != true && "$is_exec" == true ]] && prefix+="executable_"
    if [[ "$name" == .* ]]; then
        prefix+="dot_"
        name="${name#.}"
    fi
    # Escape a literal name that collides with a chezmoi attribute prefix.
    if [[ "$name" =~ ^(dot_|literal_|exact_|private_|readonly_|executable_|empty_|encrypted_|create_|modify_|remove_|symlink_|run_|once_|onchange_|before_|after_) ]]; then
        prefix+="literal_"
    fi
    printf '%s%s' "$prefix" "$name"
}

# Recursively copy a directory's CONTENTS into a chezmoi source dir, encoding
# every component. Symlinks are dereferenced; .git/.DS_Store are skipped.
# Fail-loud: a cp/mkdir failure propagates so a partial staging tree can never
# swap in (exact_ semantics would DELETE the missing live entries).
#   _cz_copy_encoded <src_dir> <dst_dir>
_cz_copy_encoded() {
    local src="$1" dst="$2" entry name enc
    mkdir -p "$dst" || return 1
    for entry in "$src"/* "$src"/.*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name="$(basename "$entry")"
        [[ "$name" == "." || "$name" == ".." || "$name" == ".git" || "$name" == ".DS_Store" ]] && continue
        if [[ -d "$entry" ]]; then
            enc="$(_cz_encode_name "$name" true false)"
            _cz_copy_encoded "$entry" "$dst/$enc" || return 1
        elif [[ -f "$entry" ]]; then
            local is_exec=false
            [[ -x "$entry" ]] && is_exec=true
            enc="$(_cz_encode_name "$name" false "$is_exec")"
            if ! cp -L "$entry" "$dst/$enc"; then
                log_error "claude source assembly: copy failed: $entry"
                return 1
            fi
        else
            # Dangling symlink or special file: it can't be vendored, and
            # dropping it silently would delete the live copy on apply.
            log_warning "claude source assembly: skipping unreadable entry: $entry"
        fi
    done
    return 0
}

# Render one claude sub-agent file: YAML frontmatter from agents/registry.yaml
# metadata + the instruction body from body_path. Mirrors ap's claude renderer
# output shape (verified by diff against a live render).
#   _cz_render_claude_agent <registry_yaml> <name> <dotfiles_root> <out_file>
_cz_render_claude_agent() {
    local registry="$1" name="$2" root="$3" out="$4"
    local body_path
    body_path=$(yq -r ".agents.\"$name\".body_path // \"\"" "$registry")
    if [[ -z "$body_path" || ! -f "$root/$body_path" ]]; then
        log_error "claude agent '$name': body_path missing (registry: $registry)"
        return 1
    fi
    {
        echo "---"
        echo "name: $name"
        yq -o=json ".agents.\"$name\"" "$registry" | jq -r '
            def line(k; v): if v == null then empty else k + ": " + v end;
            line("description";     .description),
            line("tools";           (if .tools then (.tools | join(", ")) else null end)),
            line("disallowedTools"; (if .disallowedTools then "[" + (.disallowedTools | join(", ")) + "]" else null end)),
            line("model";           .models.claude),
            line("color";           .color),
            line("effort";          .effort),
            line("maxTurns";        (if .maxTurns then (.maxTurns | tostring) else null end)),
            line("skills";          (if .skills then "[" + (.skills | join(", ")) + "]" else null end))
        '
        echo "---"
        cat "$root/$body_path"
    } > "$out"
}

# Vendor external skills (skills/_registry.yaml sources that include claude)
# into <dst>. Clones each source into a cache dir; offline falls back to the
# cached checkout with a warning. A source that has never been cloned and
# cannot be cloned fails the assembly (loud, per fail-fast). Float-to-latest
# pulls run only under `dots sync refresh` (FORCE_PACKAGES) to keep network
# off the plain-sync hot path; a pin change is always honored.
#   _cz_vendor_external_skills <skills_registry_yaml> <dst_dir>
_cz_vendor_external_skills() {
    local registry="$1" dst="$2"
    [[ -f "$registry" ]] || return 0
    local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/claude-skill-sources"
    mkdir -p "$cache_root"

    local source
    while IFS= read -r source; do
        [[ -z "$source" ]] && continue
        # Per-source harness filter: absent → all harnesses (claude included).
        local harnesses
        harnesses=$(yq -r ".sources.\"$source\".harnesses // [\"claude\"] | join(\" \")" "$registry")
        [[ " $harnesses " == *" claude "* ]] || continue

        local pin cache
        pin=$(yq -r ".sources.\"$source\".pin // \"\"" "$registry")
        cache="$cache_root/${source//\//__}"

        if [[ ! -d "$cache/.git" ]]; then
            local -a clone_args=(clone --depth 1)
            [[ -n "$pin" ]] && clone_args+=(--branch "$pin")
            if ! git "${clone_args[@]}" "https://github.com/$source" "$cache"; then
                log_error "external skill source $source: clone failed and no cache exists"
                return 1
            fi
            [[ -n "$pin" ]] && echo "$pin" > "$cache/.dotfiles-pin"
        elif [[ -n "$pin" ]]; then
            # Honor a pin change on an existing cache (pin = branch or tag per
            # the registry schema). .dotfiles-pin records the checked-out pin
            # so an unchanged pin costs no network on the sync hot path.
            if [[ "$(cat "$cache/.dotfiles-pin" 2>/dev/null)" != "$pin" ]]; then
                if git -C "$cache" fetch --depth 1 origin "$pin" >/dev/null 2>&1 \
                    && git -C "$cache" checkout --detach FETCH_HEAD >/dev/null 2>&1; then
                    echo "$pin" > "$cache/.dotfiles-pin"
                else
                    log_error "external skill source $source: cannot check out pin '$pin'"
                    return 1
                fi
            fi
        elif [[ "${FORCE_PACKAGES:-false}" == true ]]; then
            git -C "$cache" pull --ff-only >/dev/null 2>&1 \
                || log_warning "external skill source $source: pull failed, using cached checkout"
        fi

        # Explicit skill list, else every skills/<name>/SKILL.md in the source.
        local -a names=()
        local n
        while IFS= read -r n; do
            [[ -n "$n" && "$n" != "null" ]] && names+=("$n")
        done < <(yq -r ".sources.\"$source\".skills // [] | .[]" "$registry")
        if (( ${#names[@]} == 0 )); then
            local d
            for d in "$cache"/skills/*/; do
                [[ -f "$d/SKILL.md" ]] && names+=("$(basename "$d")")
            done
        fi

        local skill
        for skill in "${names[@]:-}"; do
            [[ -z "$skill" ]] && continue
            if [[ ! -d "$cache/skills/$skill" ]]; then
                log_warning "external skill source $source: skill '$skill' not found, skipping"
                continue
            fi
            _cz_copy_encoded "$cache/skills/$skill" "$dst/$(_cz_encode_name "$skill" true false)" || return 1
        done
    done < <(yq -r '.sources | keys | .[]' "$registry")
}

sync_claude_chezmoi_sources() {
    local root="$1"
    local src="${2:-$root/chezmoi}"
    local claude_reg="$src/.chezmoidata/claude.yaml"

    if ! command -v yq &>/dev/null; then
        log_warning "yq not found — skipping claude chezmoi source assembly"
        return 0
    fi
    if [[ ! -f "$claude_reg" ]]; then
        log_error "claude registry not found: $claude_reg"
        return 1
    fi

    local staging
    staging=$(mktemp -d "${TMPDIR:-/tmp}/claude-cz-src.XXXXXX") || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    # skills — registry-selected local + vendored external
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if [[ ! -d "$root/skills/$name" ]]; then
            log_error "claude registry selects unknown skill: $name (no skills/$name)"
            return 1
        fi
        _cz_copy_encoded "$root/skills/$name" "$staging/exact_skills/$(_cz_encode_name "$name" true false)" || return 1
    done < <(yq -r '.claude.skills // [] | .[]' "$claude_reg")
    _cz_vendor_external_skills "$root/skills/_registry.yaml" "$staging/exact_skills" || return 1
    mkdir -p "$staging/exact_skills"

    # agents — rendered from agents/registry.yaml
    mkdir -p "$staging/exact_agents"
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _cz_render_claude_agent "$root/agents/registry.yaml" "$name" "$root" \
            "$staging/exact_agents/$name.md" || return 1
    done < <(yq -r '.claude.agents // [] | .[]' "$claude_reg")

    # commands / hooks / lib / reference / workflows
    _cz_copy_encoded "$root/claude/commands"  "$staging/exact_commands" || return 1
    _cz_copy_encoded "$root/claude/hooks"     "$staging/exact_hooks" || return 1
    # Registry hooks (agents/hooks/registry.yaml): copy the script of every
    # claude-harness entry (default harness set includes claude).
    local hook_script
    while IFS= read -r hook_script; do
        [[ -z "$hook_script" || "$hook_script" == "null" ]] && continue
        if [[ ! -f "$root/$hook_script" ]]; then
            log_error "hook registry references missing script: $hook_script"
            return 1
        fi
        if ! cp -L "$root/$hook_script" "$staging/exact_hooks/$(_cz_encode_name "$(basename "$hook_script")" false true)"; then
            log_error "claude source assembly: hook copy failed: $hook_script"
            return 1
        fi
    done < <(yq -r '.hooks[] | select(.script != null) | select([(.harnesses // ["claude", "codex"])[] == "claude"] | any) | .script' "$root/agents/hooks/registry.yaml")
    _cz_copy_encoded "$root/agents/lib"       "$staging/exact_lib" || return 1
    _cz_copy_encoded "$root/claude/reference" "$staging/exact_reference" || return 1
    _cz_copy_encoded "$root/agents/reference" "$staging/exact_reference" || return 1
    _cz_copy_encoded "$root/claude/workflows" "$staging/exact_workflows" || return 1

    # Swap staged trees into the chezmoi source dir (all-or-nothing per dir).
    local tree
    for tree in exact_skills exact_agents exact_commands exact_hooks exact_lib exact_reference exact_workflows; do
        if ! rm -rf "${src:?}/dot_claude/$tree" \
            || ! mkdir -p "$src/dot_claude" \
            || ! mv "$staging/$tree" "$src/dot_claude/$tree"; then
            log_error "claude source assembly: staging swap failed for $tree — source state may be incomplete; rerun dots sync before chezmoi apply"
            return 1
        fi
    done
    log_info "Assembled claude chezmoi source state (dot_claude/exact_*)"
    return 0
}

# Install prek pre-commit hooks (clears conflicting core.hooksPath first)
install_prek_hooks() {
    if ! command -v prek &>/dev/null; then
        log_warning "prek not installed, skipping pre-commit hooks"
        return 0
    fi

    if git config --local core.hooksPath &>/dev/null; then
      log_info "Unsetting local core.hooksPath (conflicts with prek)..."
      git config --local --unset core.hooksPath
    fi
    log_info "Installing prek pre-commit hooks..."
    prek install 2>&1 | while read -r line; do
      log_info "  $line"
    done
}
