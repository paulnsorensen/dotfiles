#!/bin/bash
#
# Archive legacy Codex skill copies only when registry or installer metadata
# or exact content proves that the shared canonical copy owns the same skill.
#
# Usage:
#   migrate-codex-skill-duplicates.sh [legacy_root canonical_root archive_root registry manifest]
#
# The archive stays outside Codex and shared-skill discovery paths. This helper
# never deletes a skill tree, follows a skill symlink, or overwrites an archive.

set -euo pipefail

migrate_codex_skill_duplicates() {
usage() {
    echo "Usage: $0 [legacy_root canonical_root archive_root registry_file manifest_file]" >&2
    return 2
}

if [[ $# -gt 5 ]]; then
    usage
    return 2
fi

legacy_root="${1:-$HOME/.codex/skills}"
canonical_root="${2:-$HOME/.agents/skills}"
archive_root="${3:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/codex-skills-legacy}"
registry_file="${4:-}"
manifest_file="${5:-${canonical_root%/}/../.skill-lock.json}"

# A missing discovery root means there is nothing to migrate. A symlink root
# can point outside the user's home, so leave it untouched.
if [[ ! -d "$legacy_root" || ! -d "$canonical_root" ]]; then
    return 0
fi
if [[ -L "$legacy_root" || -L "$canonical_root" ]]; then
    echo "  Skipping Codex skill migration: a discovery root is a symlink" >&2
    return 0
fi

# The registry is required when candidates exist. Check it now so a malformed
# or missing source cannot turn an uncertain ownership decision into a move.
if [[ -z "$registry_file" || ! -f "$registry_file" ]]; then
    echo "  ERROR: Codex skill migration registry is missing: ${registry_file:-<unset>}" >&2
    return 1
fi
if ! command -v yq >/dev/null 2>&1; then
    echo "  ERROR: Codex skill migration needs yq" >&2
    return 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "  ERROR: Codex skill migration needs python3" >&2
    return 1
fi

normalize_path() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

check_discovery_roots() {
    case "$legacy_root/" in
        "$canonical_root/"*)
            echo "  ERROR: Codex skill discovery roots overlap: $legacy_root and $canonical_root" >&2
            return 1
            ;;
    esac
    case "$canonical_root/" in
        "$legacy_root/"*)
            echo "  ERROR: Codex skill discovery roots overlap: $legacy_root and $canonical_root" >&2
            return 1
            ;;
    esac
}

check_archive_root() {
    case "$archive_root/" in
        "$legacy_root/"*|"$canonical_root/"*)
            echo "  ERROR: Codex skill archive must stay outside discovery roots: $archive_root" >&2
            return 1
            ;;
    esac
    if [[ -e "$archive_root" && ! -d "$archive_root" ]]; then
        echo "  ERROR: Codex skill archive path is not a directory: $archive_root" >&2
        return 1
    fi
}

legacy_root="$(normalize_path "$legacy_root")" || return 1
canonical_root="$(normalize_path "$canonical_root")" || return 1
check_discovery_roots || return 1
archive_root="$(normalize_path "$archive_root")" || return 1
check_archive_root || return 1

tree_has_symlink() {
    local tree="$1"
    [[ -n "$(find -P "$tree" -type l -print -quit 2>/dev/null)" ]]
}

metadata_value() {
    local key="$1" file="$2"
    yq -r --front-matter=extract \
        ".[\"$key\"] // .metadata[\"$key\"] // \"\"" "$file" 2>/dev/null
}

registry_owns_skill() {
    local name="$1" repo="$2" skill_path="$3"
    local source_exists

    [[ "$repo" == https://github.com/* ]] || return 1
    repo="${repo#https://github.com/}"
    repo="${repo%.git}"
    repo="${repo%/}"
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    [[ "$skill_path" == "skills/$name" || "$skill_path" == ".agents/skills/$name" ]] || return 1

    # shellcheck disable=SC2016
    source_exists=$(
        yq -o=json '.' "$registry_file" 2>/dev/null |
            jq -r --arg repo "$repo" --arg name "$name" '
                .sources[$repo] as $source
                | if $source == null then false
                  elif (($source.harnesses // []) | length) > 0
                       and (($source.harnesses // []) | index("codex")) == null then false
                  elif (($source.skills // []) | length) == 0 then true
                  else (($source.skills // []) | index($name)) != null
                  end
            ' 2>/dev/null
    ) || return 1
    [[ "$source_exists" == "true" ]]
}

normalize_repo() {
    local repo="$1"
    [[ "$repo" == https://github.com/* ]] || return 1
    repo="${repo#https://github.com/}"
    repo="${repo%.git}"
    repo="${repo%/}"
    printf '%s\n' "$repo"
}

metadata_identity_matches() {
    local legacy_file="$1" canonical_file="$2"
    local legacy_repo canonical_repo legacy_path canonical_path
    legacy_repo="$(normalize_repo "$(metadata_value github-repo "$legacy_file")")" || return 1
    canonical_repo="$(normalize_repo "$(metadata_value github-repo "$canonical_file")")" || return 1
    legacy_path="$(metadata_value github-path "$legacy_file")" || return 1
    canonical_path="$(metadata_value github-path "$canonical_file")" || return 1
    [[ "$legacy_repo" == "$canonical_repo" && "$legacy_path" == "$canonical_path" ]]
}

metadata_proves_ownership() {
    local name="$1" skill_file="$2" repo skill_path
    repo="$(metadata_value github-repo "$skill_file")" || return 1
    skill_path="$(metadata_value github-path "$skill_file")" || return 1
    registry_owns_skill "$name" "$repo" "$skill_path"
}

normalize_manifest_repo() {
    local repo="$1"
    repo="${repo%/}"
    repo="${repo%.git}"
    repo="${repo%/}"
    if [[ "$repo" == https://github.com/* ]]; then
        normalize_repo "$repo"
        return
    fi
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s\n' "$repo"
}

manifest_value() {
    local name="$1" key="$2"
    [[ -f "$manifest_file" ]] || return 1
    # shellcheck disable=SC2016
    yq -o=json '.' "$manifest_file" 2>/dev/null |
        jq -r --arg name "$name" --arg key "$key" '
            .skills[$name] as $skill
            | if ($skill | type) != "object" then ""
              else ($skill[$key] // "")
              end
        ' 2>/dev/null
}

manifest_version() {
    [[ -f "$manifest_file" ]] || return 1
    yq -o=json '.' "$manifest_file" 2>/dev/null | jq -r '.version // empty'
}

manifest_proves_ownership() {
    local name="$1" legacy_file="$2"
    local legacy_repo legacy_path manifest_source manifest_type manifest_url manifest_path

    metadata_proves_ownership "$name" "$legacy_file" || return 1
    [[ "$(manifest_version)" == "3" ]] || return 1
    legacy_repo="$(normalize_repo "$(metadata_value github-repo "$legacy_file")")" || return 1
    legacy_path="$(metadata_value github-path "$legacy_file")" || return 1
    manifest_source="$(manifest_value "$name" source)" || return 1
    manifest_source="$(normalize_manifest_repo "$manifest_source")" || return 1
    manifest_type="$(manifest_value "$name" sourceType)" || return 1
    manifest_url="$(manifest_value "$name" sourceUrl)" || return 1
    manifest_url="$(normalize_repo "$manifest_url")" || return 1
    manifest_path="$(manifest_value "$name" skillPath)" || return 1

    [[ "$legacy_path" == "skills/$name" || "$legacy_path" == ".agents/skills/$name" ]] || return 1
    [[ "$manifest_path" == "skills/$name/SKILL.md" || "$manifest_path" == ".agents/skills/$name/SKILL.md" ]] || return 1
    [[ "$manifest_source" == "$legacy_repo" ]] || return 1
    [[ "$manifest_type" == "github" ]] || return 1
    [[ "$manifest_url" == "$legacy_repo" ]] || return 1
    [[ "$manifest_path" == "${legacy_path%/}/SKILL.md" ]]
}

trees_match() {
    local legacy="$1" canonical="$2"
    diff -qr "$legacy" "$canonical" >/dev/null 2>&1
}

proven_duplicate() {
    local name="$1" legacy="$2" canonical="$3"
    local skill_file="$legacy/SKILL.md"

    [[ -f "$skill_file" && -f "$canonical/SKILL.md" ]] || return 1
    tree_has_symlink "$legacy" && return 1
    tree_has_symlink "$canonical" && return 1

    # Both copies must identify the same eligible registry source. A metadata-free
    # canonical copy may use the skills CLI lockfile as its provenance record.
    if metadata_proves_ownership "$name" "$skill_file" \
        && metadata_proves_ownership "$name" "$canonical/SKILL.md" \
        && metadata_identity_matches "$skill_file" "$canonical/SKILL.md"; then
        return 0
    fi
    if [[ -z "$(metadata_value github-repo "$canonical/SKILL.md")" \
        && -z "$(metadata_value github-path "$canonical/SKILL.md")" ]] \
        && manifest_proves_ownership "$name" "$skill_file"; then
        return 0
    fi
    # Exact tree equality remains a safe fallback for older copies without
    # frontmatter or lockfile provenance.
    trees_match "$legacy" "$canonical"
}

archive_skill() {
    local name="$1" source="$2"
    local destination suffix=1

    mkdir -p "$archive_root"
    archive_root="$(normalize_path "$archive_root")" || return 1
    check_archive_root || return 1
    destination="$archive_root/$name"
    while [[ -e "$destination" || -L "$destination" ]]; do
        destination="$archive_root/${name}.backup-$suffix"
        suffix=$((suffix + 1))
    done
    mv "$source" "$destination"
    echo "  Archived legacy Codex skill: $name -> $destination"
}

is_plugin_root() {
    local tree="$1"
    [[ -d "$tree/.claude-plugin" || -d "$tree/.codex-plugin" || \
        -f "$tree/plugin.json" || -f "$tree/marketplace.json" ]]
}

for legacy_path in "$legacy_root"/* "$legacy_root"/.[!.]* "$legacy_root"/..?*; do
    [[ -e "$legacy_path" || -L "$legacy_path" ]] || continue
    name="${legacy_path##*/}"

    # Codex's own .system payload and all symlink entries remain untouched.
    [[ "$name" == ".system" ]] && continue
    [[ -L "$legacy_path" || ! -d "$legacy_path" ]] && continue
    is_plugin_root "$legacy_path" && continue

    canonical_path="$canonical_root/$name"
    [[ -d "$canonical_path" && ! -L "$canonical_path" ]] || continue

    if proven_duplicate "$name" "$legacy_path" "$canonical_path"; then
        archive_skill "$name" "$legacy_path"
    fi
done

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    migrate_codex_skill_duplicates "$@"
fi
