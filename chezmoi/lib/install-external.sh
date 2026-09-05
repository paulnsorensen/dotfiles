#!/bin/bash
#
# install-external.sh — Install agent skills via `npx skills add` per source repo
#
# Reads SKILL_HARNESSES from .env (space-separated `skills`-CLI agent IDs, e.g.
# "claude-code cursor github-copilot codex") and installs the skills from each
# source repo in the given registry into every harness at user (global) scope.
# A per-source `harnesses:` list (ap harness names, e.g. [claude]) restricts
# installation to only those harnesses, overriding SKILL_HARNESSES for that entry.
#
# Why `npx skills` (the Vercel `skills` CLI) over `gh skill install`: gh fetched
# every file of every skill via individual GitHub blob-API calls — files ×
# skills × harnesses round-trips, any one of which could reset mid-stream and
# abort the whole sync. `npx skills add` does a single `git clone --depth 1` per
# source repo and installs to every requested agent in one invocation,
# collapsing the network surface to one connection per source.
#
# Usage:
#   install-external.sh <registry_path>           Install/update all skills
#   install-external.sh <registry_path> --dry-run Show what would change
#

set -euo pipefail

# Chezmoi already owns codex, copilot, zed, and omp's skill delivery (the
# shared ~/.agents/skills dir assembled by `dots sync`); this npx leg must
# never install into or reconcile them. Two lists because the two call
# sites use different id namespaces: SKILL_HARNESSES/CHEZMOI_OWNED_AGENTS
# carries `skills`-CLI agent ids, harnesses:/CHEZMOI_OWNED_HARNESSES carries
# `ap` harness names.
CHEZMOI_OWNED_HARNESSES="codex copilot zed omp"
CHEZMOI_OWNED_AGENTS="codex github-copilot zed"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <registry_path> [--dry-run]" >&2
    exit 2
fi

REGISTRY_FILE="$1"
shift

SCRIPT_DIR="$(cd "${BASH_SOURCE%/*}" && pwd)"
# Script lives at chezmoi/lib/, dotfiles root is two levels up.
DOTFILES_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../claude/lib/sync-common.sh
source "$DOTFILES_DIR/claude/lib/sync-common.sh"

sync_parse_args "$@"

# Skill sync needs npx (Node) + yq + jq. `npx skills add` clones each source and
# places skills into each agent's skill dir; npx fetches the `skills` CLI itself
# (float-to-latest, no pin).
for cmd in npx yq jq; do
    if ! command -v "$cmd" &> /dev/null; then
        case "$cmd" in
            npx) hint="Install Node (provides npm/npx)" ;;
            *)   hint="brew install $cmd" ;;
        esac
        echo -e "${RED}Error: $cmd not found. $hint${NC}" >&2
        exit 1
    fi
done

# Source .env for SKILL_HARNESSES
if [[ -f "$DOTFILES_DIR/.env" ]]; then
    env_line=0
    while IFS='=' read -r key val; do
        env_line=$((env_line + 1))
        key="${key#export }"
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        # `export` aborts the script on a key that is not a shell identifier —
        # a whitespace-only line or a `KEY = value` spacing slip is enough — so
        # reject those here instead of letting one stray line kill the install.
        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            [[ "$key" =~ ^[[:space:]]*$ ]] ||
                echo -e "${YELLOW}Warning: ignoring .env line $env_line (not KEY=value)${NC}" >&2
            continue
        fi
        # Strip surrounding quotes from value (env loader is naive)
        val="${val%\"}"
        val="${val#\"}"
        export "$key=$val"
    done < "$DOTFILES_DIR/.env"
fi

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo -e "${RED}Error: Registry file not found at $REGISTRY_FILE${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Skill Sync - Declarative Skill Management${NC}"
echo

HARNESSES="${SKILL_HARNESSES:-}"
# Drop chezmoi-owned agent ids before any other filtering, silently: this
# npx leg must never install into codex, github-copilot, or zed, wherever
# they come from (dots sync already owns their skill delivery).
if [[ -n "$HARNESSES" ]]; then
    _filtered=""
    for _h in $HARNESSES; do
        case " ${CHEZMOI_OWNED_AGENTS} " in
            *" ${_h} "*) continue ;;
        esac
        _filtered="${_filtered:+$_filtered }$_h"
    done
    HARNESSES="$_filtered"
fi
# SKILL_EXCLUDE_AGENTS (space-separated agent IDs) subtracts from the harness
# list. `dots sync` passes claude-code: ~/.claude/skills is chezmoi-managed
# (exact_) and external skills are vendored into source state by
# sync_claude_chezmoi_sources — installing them live would just be deleted on
# the next apply (spec: chezmoi-authoritative-claude).
if [[ -n "${SKILL_EXCLUDE_AGENTS:-}" ]]; then
    _filtered=""
    for _h in $HARNESSES; do
        case " ${SKILL_EXCLUDE_AGENTS} " in
            *" ${_h} "*) echo "  Excluding harness: ${_h} (SKILL_EXCLUDE_AGENTS)" ;;
            *) _filtered="${_filtered:+$_filtered }$_h" ;;
        esac
    done
    HARNESSES="$_filtered"
fi
if [[ -z "$HARNESSES" ]]; then
    echo -e "${YELLOW}SKILL_HARNESSES is empty in .env — nothing to do.${NC}"
    echo "Set SKILL_HARNESSES in .env to a space-separated list of agent IDs."
    echo "Example: SKILL_HARNESSES=\"claude-code cursor codex\""
    exit 0
fi

echo -e "${BLUE}Harnesses:${NC} $HARNESSES"
echo

# Cache: skip when registry content + harness list match the last successful
# run. Bust with --force, by deleting $CACHE_FILE, or by running
# `npx skills update --global -y` to pull upstream changes.
CACHE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/skill-external-hash"
REGISTRY_DIGEST=$(shasum -a 256 "$REGISTRY_FILE" | awk '{print $1}')
COMBINED_DIGEST=$(printf '%s\n%s\n' "$REGISTRY_DIGEST" "$HARNESSES" | shasum -a 256 | awk '{print $1}')

if ! $FORCE && ! $DRY_RUN && [[ -f "$CACHE_FILE" ]] && [[ "$(cat "$CACHE_FILE" 2>/dev/null)" == "$COMBINED_DIGEST" ]]; then
    echo -e "${GREEN}Registry + harnesses unchanged since last sync — skipping.${NC}"
    echo "  Pass --force, delete $CACHE_FILE, or run 'npx --yes skills update --global -y' to refresh."
    exit 0
fi

# Failure counter (one line per failed source).
FAIL_COUNTER=$(mktemp "${TMPDIR:-/tmp}/skill-fail.XXXXXX")
export FAIL_COUNTER
trap 'rm -f "$FAIL_COUNTER"' EXIT

# Repeated `--agent <id>` flags, one per harness. The CLI rejects a
# comma/space-joined value (and silently no-ops at exit 0 for a bad agent), so
# every agent is its own flag. Validate against the known set up-front:
# `npx skills add --agent <bogus>` would otherwise succeed (exit 0) having
# installed nothing, and the cache below would then be written as if the run
# worked — silently masking the misconfiguration until --force.
#
# The canonical set lives in agent-profile/agent_profile/skill_agents.txt,
# which fetch.py loads as SKILL_AGENT (keys) -> agent ID (values). Extracting
# the values here means the ap path and this legacy path share one source of
# truth — adding a harness in that file makes it valid in both, by design.
SKILL_AGENTS_FILE="$DOTFILES_DIR/agent-profile/agent_profile/skill_agents.txt"
if [[ ! -f "$SKILL_AGENTS_FILE" ]]; then
    echo -e "${RED}Error: canonical skill-agents map not found at $SKILL_AGENTS_FILE${NC}" >&2
    echo "  Expected the shared truth-source (fetch.py reads the same file)." >&2
    exit 1
fi
KNOWN_AGENTS=$(awk -F= '/^[[:space:]]*#/ {next} NF==2 {gsub(/[[:space:]]/, "", $2); print $2}' "$SKILL_AGENTS_FILE" | tr '\n' ' ')

AGENT_FLAGS=()
SKIPPED_AGENTS=()
SUPPORTED_HARNESSES=""
for harness in $HARNESSES; do
    if [[ " $KNOWN_AGENTS" != *" $harness "* ]]; then
        SKIPPED_AGENTS+=("$harness")
        continue
    fi
    AGENT_FLAGS+=(--agent "$harness")
    SUPPORTED_HARNESSES+="${SUPPORTED_HARNESSES:+ }$harness"
done

# Filter rather than fail: SKILL_HARNESSES can include agents unsupported by
# the `skills` CLI (for example antigravity). Skipping them with a loud warning
# lets supported agents continue instead of aborting the refresh.
if (( ${#SKIPPED_AGENTS[@]} > 0 )); then
    echo -e "${YELLOW}Skipping SKILL_HARNESSES agents the 'skills' CLI doesn't support: ${SKIPPED_AGENTS[*]}${NC}" >&2
    echo "  Supported: $KNOWN_AGENTS" >&2
    echo "  (canonical set: $SKILL_AGENTS_FILE — add an agent there to enable it)" >&2
fi

if (( ${#AGENT_FLAGS[@]} == 0 )); then
    echo -e "${YELLOW}No supported SKILL_HARNESSES agents to install into — nothing to do.${NC}" >&2
    exit 0
fi

# Repeated `--skill` flags for a source: the explicit registry list (one flag
# per name), or `--skill '*'` to install every skill in the repo (the CLI's
# native auto-discovery — no GitHub-API listing needed). Echoes one token per
# line so the caller can read them into an array safely.
skill_flags() {
    local repo="$1" explicit
    explicit=$(yq -o=json ".sources.\"$repo\".skills // []" "$REGISTRY_FILE" | jq -r '.[]?')
    if [[ -n "$explicit" ]]; then
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            printf '%s\n%s\n' "--skill" "$s"
        done <<< "$explicit"
    else
        printf '%s\n%s\n' "--skill" "*"
    fi
}

# Resolve the source's declarative skill set. Explicit lists are complete. A
# wildcard source uses the checkout refreshed by the chezmoi assembly step.
source_skill_names() {
    local repo="$1" explicit skills_path cache root d
    explicit=$(yq -r ".sources.\"$repo\".skills // [] | .[]" "$REGISTRY_FILE")
    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi

    skills_path=$(yq -r ".sources.\"$repo\".skills_path // \"skills\"" "$REGISTRY_FILE")
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/claude-skill-sources/${repo//\//__}"
    if [[ ! -d "$cache" ]]; then
        echo -e "    ${YELLOW}Cannot reconcile retired skills for $repo: vendor cache not found at $cache${NC}" >&2
        return 1
    fi
    for root in "$cache/$skills_path" "$cache/.agents/skills"; do
        [[ -d "$root" ]] || continue
        for d in "$root"/*/; do
            [[ -f "$d/SKILL.md" ]] && basename "$d"
        done
    done
}

remove_stale_source_skills() {
    local repo="$1" allowed_agents="$2" expected installed stale_output name _id
    expected=$(source_skill_names "$repo") || return 1
    if ! installed=$(npx --yes skills list --global --json 2>&1); then
        echo -e "    ${RED}Could not list installed skills before reconciling $repo${NC}" >&2
        return 1
    fi
    if ! stale_output=$(jq -r --arg source "$repo" --arg expected "$expected" '
        ($expected | split("\n") | map(select(length > 0))) as $keep
        | .[]
        | .name as $name
        | select(.source == $source and ($keep | index($name)) == null)
        | $name
    ' <<<"$installed"); then
        echo -e "    ${RED}Could not parse installed skills while reconciling $repo${NC}" >&2
        return 1
    fi
    [[ -n "$stale_output" ]] || return 0

    local -a stale=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && stale+=("$name")
    done <<<"$stale_output"
    local -a agent_flags=()
    for _id in $allowed_agents; do
        agent_flags+=(--agent "$_id")
    done
    npx --yes skills remove "${stale[@]}" --global -y "${agent_flags[@]}" >/dev/null
    echo -e "    ${GREEN}Removed retired skills:${NC} ${stale[*]}"
}

# Install every skill from one source repo into all harnesses in a single
# `npx skills add` (one shallow clone, repeated --agent for the harnesses).
# If the registry entry has a `harnesses:` list (ap harness names, e.g. [claude]),
# only those harnesses are targeted; otherwise falls back to all SKILL_HARNESSES.
install_source() {
    local repo="$1" pin="$2"
    local spec="$repo"
    [[ -n "$pin" && "$pin" != "null" ]] && spec="$repo@$pin"

    local skill_args=()
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        skill_args+=("$tok")
    done < <(skill_flags "$repo")

    # Per-repo harness restriction: if `harnesses:` is set, build a filtered
    # agent-flags array from the ap harness names (mapped via skill_agents.txt).
    # Falls back to the global AGENT_FLAGS when unset.
    local repo_agent_flags=("${AGENT_FLAGS[@]}")
    local repo_supported="$SUPPORTED_HARNESSES"
    local raw_harnesses
    raw_harnesses=$(yq -o=json ".sources.\"$repo\".harnesses // []" "$REGISTRY_FILE" | jq -r '.[]?')
    if [[ -n "$raw_harnesses" ]]; then
        repo_agent_flags=()
        repo_supported=""
        local repo_excluded=0 repo_dropped_other=0 repo_dropped_owned=0
        while IFS= read -r ap_name; do
            [[ -z "$ap_name" ]] && continue
            case " ${CHEZMOI_OWNED_HARNESSES} " in
                *" ${ap_name} "*) repo_dropped_owned=$((repo_dropped_owned + 1)); continue ;;
            esac
            local cli_id
            cli_id=$(awk -F= -v key="$ap_name" \
                '!/^[[:space:]]*#/ && NF==2 { gsub(/[[:space:]]/, "", $1); gsub(/[[:space:]]/, "", $2); if ($1 == key) print $2 }' \
                "$SKILL_AGENTS_FILE")
            if [[ -z "$cli_id" ]]; then
                echo -e "    ${YELLOW}Skipping unknown harness '$ap_name' for $repo (not in skill_agents.txt)${NC}" >&2
                repo_dropped_other=$((repo_dropped_other + 1))
                continue
            fi
            if [[ " $KNOWN_AGENTS" != *" $cli_id "* ]]; then
                echo -e "    ${YELLOW}Skipping '$ap_name' ($cli_id) for $repo (not a supported skills CLI agent)${NC}" >&2
                repo_dropped_other=$((repo_dropped_other + 1))
                continue
            fi
            if [[ " ${SKILL_EXCLUDE_AGENTS:-} " == *" $cli_id "* ]]; then
                echo -e "    ${BLUE}Excluding harness '$ap_name' ($cli_id) for $repo (SKILL_EXCLUDE_AGENTS)${NC}"
                repo_excluded=$((repo_excluded + 1))
                continue
            fi
            repo_agent_flags+=(--agent "$cli_id")
            repo_supported="${repo_supported:+$repo_supported }$cli_id"
        done <<< "$raw_harnesses"
        if (( ${#repo_agent_flags[@]} == 0 )); then
            # All-excluded (via SKILL_EXCLUDE_AGENTS) with no genuinely bad
            # harness is expected — e.g. a claude-only source on `dots sync`,
            # where claude skills are vendored via chezmoi, not this npx leg.
            # Only warn when a harness was actually unknown/unsupported.
            if (( repo_dropped_other == 0 && repo_excluded == 0 && repo_dropped_owned > 0 )); then
                echo -e "    ${BLUE}$repo → nothing for this leg (all harnesses are chezmoi-owned, dropped silently).${NC}"
            elif (( repo_dropped_other == 0 && repo_excluded > 0 )); then
                echo -e "    ${BLUE}$repo → nothing for this leg (all harnesses excluded via SKILL_EXCLUDE_AGENTS).${NC}"
            else
                echo -e "    ${YELLOW}No valid harnesses for $repo — skipping.${NC}"
            fi
            return 0
        fi
    fi

    # `--yes` runs npx non-interactively (auto-installs the `skills` CLI); the
    # CLI's own `-y` skips its scope/confirmation prompts. `-g` = user scope,
    # `--copy` copies files (vs symlinking) to match the old overwrite contract.
    local args=(--yes skills add "$spec" "${skill_args[@]}" "${repo_agent_flags[@]}" -g --copy -y)

    if $DRY_RUN; then
        echo -e "    ${BLUE}[dry-run]${NC} npx ${args[*]}"
        return 0
    fi

    local output
    if output=$(GIT_TERMINAL_PROMPT=0 npx "${args[@]}" 2>&1); then
        if remove_stale_source_skills "$repo" "$repo_supported"; then
            echo -e "    ${GREEN}✓${NC} $repo → $repo_supported"
        else
            echo -e "    ${RED}✗${NC} $repo → cleanup failed"
            echo x >> "$FAIL_COUNTER"
        fi
    else
        echo -e "    ${RED}✗${NC} $repo → $repo_supported"
        echo x >> "$FAIL_COUNTER"
        if [[ -n "$output" ]]; then
            echo "$output" | tail -5 | sed -e "s/^/      /"
        fi
    fi
}

SOURCES=$(yq -o=json '.sources' "$REGISTRY_FILE" | jq -r 'keys[]')
if [[ -z "$SOURCES" ]]; then
    echo -e "${YELLOW}No sources defined in registry.${NC}"
    exit 0
fi

for repo in $SOURCES; do
    description=$(yq -r ".sources.\"$repo\".description // \"\"" "$REGISTRY_FILE")
    pin=$(yq -r ".sources.\"$repo\".pin // \"\"" "$REGISTRY_FILE")

    echo -e "${BLUE}Source:${NC} $repo"
    [[ -n "$description" ]] && echo "  $description"

    install_source "$repo" "$pin"
    echo
done

fail_count=0
if [[ -s "$FAIL_COUNTER" ]]; then
    fail_count=$(wc -l < "$FAIL_COUNTER" | tr -d ' ')
fi

if [[ "$fail_count" -gt 0 ]]; then
    # Fail loud: propagate non-zero so the chezmoi run_onchange records the
    # apply as failed and reruns next `dots sync` instead of marking success
    # and skipping until the skills tree hash changes (the silent partial
    # install regression mode).
    echo -e "${RED}$fail_count source(s) failed — cache not updated. Re-run to retry.${NC}" >&2
    exit 1
fi

if ! $DRY_RUN; then
    mkdir -p "$(dirname "$CACHE_FILE")"
    echo "$COMBINED_DIGEST" > "$CACHE_FILE"
fi

echo -e "${GREEN}Sync complete!${NC}"
echo
echo -e "${BLUE}Run 'npx --yes skills update --global -y' to refresh installed skills.${NC}"
