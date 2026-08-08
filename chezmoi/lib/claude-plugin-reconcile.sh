#!/bin/bash
# claude-plugin-reconcile.sh — prime native-claude plugin marketplaces in the
# claude CLI runtime state and prune the ones this reconcile previously added.
#
# Sourced as a lib (tested by tests/claude-plugin-reconcile.bats); the thin
# run_onchange script resolves the desired native-claude entries from
# agents/plugins/registry.yaml and dispatches here.
#
# Contract (spec: native-plugin-bridge, Leg 2 — mirrors claude-mcp-reconcile):
#   * settings.json (composed by modify_settings.json) enables the plugins and
#     lists their marketplaces, but the CLI does not INDEX a marketplace until
#     `claude plugin marketplace add <root>` runs. This primes that index.
#   * All writes go through the `claude plugin marketplace` CLI — never a direct
#     edit of ~/.claude/plugins/known_marketplaces.json.
#   * A manifest (~/.claude/.chezmoi-plugin-manifest) records the marketplace
#     NAMES this reconcile owns. Manifest names no longer desired are REMOVED.
#   * Desired native plugins are INSTALLED at user scope via the CLI (enabling
#     via settings.json does not populate installed_plugins.json). Retired
#     user-scope installs whose marketplace the manifest proves ours are
#     UNINSTALLED. Project-scope installs are never touched — a dead projectPath
#     is only surfaced as a NOTE. All via the CLI, never a direct file edit.
#   * Marketplaces outside the manifest were added by hand (or by the app) —
#     they are NEVER removed. Dead directory sources among them are printed as
#     a NOTE so the user can clean them up by hand.
#   * Missing `claude` CLI is non-fatal: the durable settings.json write already
#     happened; priming is best-effort. Warn and return 0.

# _cheese_atomic_link_replace <source_link> <destination>
#   GNU mv needs -T to replace a symlink-to-directory rather than following it;
#   BSD/macOS mv uses -h for the same operation.
_cheese_atomic_link_replace() {
    local source_link="$1" destination="$2"
    if mv -Tf -- "$source_link" "$destination" 2>/dev/null; then
        return 0
    fi
    mv -fh "$source_link" "$destination"
}

# cheese_plugin_cache_prepare <registry> <cache_root>
#   Clone every git-backed marketplace before publishing anything. Successful
#   runs publish one immutable content-addressed generation through .current;
#   stable per-plugin symlinks follow that pointer. Old generations remain valid
#   for readers that resolved them before publication.
cheese_plugin_cache_prepare() (
    set -euo pipefail

    local registry="$1" cache_root="$2" registry_json rows
    local key url branch commit generation generations generation_root
    local staging="" lock="${cache_root}.lock" manifest destination link_tmp

    for command_name in git jq yq; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            echo "  ERROR: $command_name not found — plugin cache cannot be prepared" >&2
            return 1
        fi
    done
    if ! registry_json=$(yq -o=json '.plugins // {}' "$registry"); then
        echo "  ERROR: invalid plugin registry: $registry" >&2
        return 1
    fi
    if ! rows=$(jq -r '
        to_entries[]
        | select((.value | type) == "object" and (.value | has("git")))
        | [
            .key,
            (if (.value.git | type) == "string" and (.value.git | length) > 0
             then .value.git else error("git must be a non-empty string") end),
            (if (.value.branch // "main") | type == "string" and length > 0
             then (.value.branch // "main") else error("branch must be a non-empty string") end)
          ]
        | @tsv
    ' <<<"$registry_json"); then
        echo "  ERROR: invalid git plugin metadata in $registry" >&2
        return 1
    fi

    mkdir -p "$cache_root"
    if ! mkdir "$lock" 2>/dev/null; then
        echo "  ERROR: plugin cache preparation already holds $lock" >&2
        return 1
    fi
    # shellcheck disable=SC2329  # Invoked by the EXIT trap below.
    cleanup_plugin_cache_prepare() {
        [[ -z "$staging" ]] || rm -rf -- "$staging"
        rm -f -- "$cache_root/.current.$$.tmp" "$cache_root"/.*.link.$$
        rm -rf -- "$lock"
    }
    trap cleanup_plugin_cache_prepare EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    staging=$(mktemp -d "${cache_root}.stage.XXXXXX")
    manifest="$staging/.commits"
    : > "$manifest"
    while IFS="$(printf '\t')" read -r key url branch; do
        [[ -z "$key" ]] && continue
        case "$key" in
            (.*|*[!A-Za-z0-9._-]*)
                echo "  ERROR: unsafe plugin cache key: $key" >&2
                return 1
                ;;
        esac
        if ! git clone --quiet --depth 1 --branch "$branch" --single-branch -- "$url" "$staging/$key"; then
            echo "  ERROR: failed to prepare plugin cache for $key" >&2
            return 1
        fi
        commit=$(git -C "$staging/$key" rev-parse HEAD)
        printf '%s\t%s\n' "$key" "$commit" >> "$manifest"
    done <<<"$rows"

    generation=$(git hash-object "$manifest")
    generations="$cache_root/.generations"
    generation_root="$generations/$generation"
    mkdir -p "$generations"
    if [[ -e "$generation_root" ]]; then
        if [[ ! -f "$generation_root/.commits" ]] \
            || [[ "$(git hash-object "$generation_root/.commits")" != "$generation" ]]; then
            echo "  ERROR: plugin cache generation $generation has invalid metadata" >&2
            return 1
        fi
        while IFS="$(printf '\t')" read -r key commit; do
            [[ -z "$key" ]] && continue
            if [[ ! -d "$generation_root/$key/.git" ]] \
                || [[ "$(git -C "$generation_root/$key" rev-parse HEAD)" != "$commit" ]] \
                || [[ -n "$(git -C "$generation_root/$key" status --porcelain)" ]]; then
                echo "  ERROR: plugin cache generation $generation is corrupt at $key" >&2
                return 1
            fi
        done < "$manifest"
        rm -rf -- "$staging"
        staging=""
    else
        mv -- "$staging" "$generation_root"
        staging=""
    fi

    ln -s ".generations/$generation" "$cache_root/.current.$$.tmp"
    _cheese_atomic_link_replace "$cache_root/.current.$$.tmp" "$cache_root/.current"

    while IFS="$(printf '\t')" read -r key commit; do
        [[ -z "$key" ]] && continue
        destination="$cache_root/$key"
        link_tmp="$cache_root/.$key.link.$$"
        ln -s ".current/$key" "$link_tmp"
        if [[ -e "$destination" && ! -L "$destination" ]]; then
            mv -- "$destination" "$cache_root/.legacy.$key.$$"
            if ! _cheese_atomic_link_replace "$link_tmp" "$destination"; then
                mv -- "$cache_root/.legacy.$key.$$" "$destination"
                return 1
            fi
        else
            _cheese_atomic_link_replace "$link_tmp" "$destination"
        fi
    done < "$generation_root/.commits"

    for destination in "$cache_root"/*; do
        [[ -e "$destination" || -L "$destination" ]] || continue
        [[ -L "$destination" ]] || continue
        key=${destination##*/}
        [[ -e "$generation_root/$key" ]] || rm -f -- "$destination"
    done
)

# claude_plugin_reconcile <desired_json> <known_file> <manifest_path> [installed_file]
#   desired_json  — JSON array of {key, marketplace_root} for native-claude
#                   entries (resolved the same way as the modify_settings.json
#                   native overlay).
#   known_file    — path to the live ~/.claude/plugins/known_marketplaces.json
#   manifest_path — path to the ownership manifest
#   installed_file — path to ~/.claude/plugins/installed_plugins.json (optional;
#                    empty/absent skips the install/uninstall reconcile)
claude_plugin_reconcile() {
    local desired_json="$1" known_file="$2" manifest="$3" installed_file="${4:-}"

    # Missing claude CLI is non-fatal here (unlike the MCP reconcile): the
    # settings.json write is the durable state; priming only builds the CLI's
    # runtime index, which the next sync (after the CLI installs) will do.
    if ! command -v claude >/dev/null 2>&1; then
        echo "  WARN: claude CLI not found — plugin marketplace prime skipped (settings.json already written)." >&2
        return 0
    fi

    # No mapfile — must run under macOS /bin/bash 3.2 (chezmoi scripts).
    local -a desired_keys=() owned_names=() owned_ids=() prior_names=()
    local key root name mp_json _n rc=0 any_missing=0

    # Desired keys come from the registry-derived desired_json, INDEPENDENT of
    # cache presence: a transiently missing cache is still a desired plugin and
    # must never be treated as retired.
    while IFS= read -r _n; do [[ -n "$_n" ]] && desired_keys+=("$_n"); done \
        < <(jq -r '.[].key' <<<"$desired_json")

    _in() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }
    _user_installed() { [[ -f "$installed_file" ]] && jq -e --arg id "$1" '(.plugins[$id] // []) | any(.scope == "user")' "$installed_file" >/dev/null 2>&1; }

    # ── prime ──────────────────────────────────────────────────────────────
    # Add each desired marketplace by root; record its canonical name (taken
    # from marketplace.json, authoritative) for the manifest.
    while IFS="$(printf '\t')" read -r key root; do
        [[ -z "$key" ]] && continue
        mp_json="$root/.claude-plugin/marketplace.json"
        if [[ ! -f "$mp_json" ]]; then
            echo "  WARN: native plugin '$key' cache missing marketplace.json ($mp_json) — still desired; retaining its manifest entry and deferring prune until the cache clones." >&2
            any_missing=1
            continue
        fi
        name=$(jq -r '.name // empty' "$mp_json")
        if [[ -z "$name" ]]; then
            echo "  WARN: native plugin '$key' marketplace.json has no .name ($mp_json) — cannot resolve its marketplace; deferring prune." >&2
            any_missing=1
            continue
        fi
        owned_names+=("$name")
        owned_ids+=("$key@$name")
        echo "  Priming marketplace: $name ($root)"
        if ! claude plugin marketplace add "$root" >/dev/null 2>&1; then
            echo "  WARN: 'claude plugin marketplace add $root' failed — '$name' not indexed; settings.json enables it but the CLI cannot resolve it until primed." >&2
            rc=1
        fi
    done < <(jq -r '.[] | [.key, .marketplace_root] | @tsv' <<<"$desired_json")

    # ── install desired plugins at user scope ────────────────────────────────
    # Enabling via settings.json does not populate installed_plugins.json; the
    # CLI must install. Idempotent: skip ids already user-installed. Verify by
    # post-condition rather than exit code: `claude plugin install`'s exit code
    # does not distinguish a real failure from an "already installed" nonzero,
    # so re-read installed_file and assert the id landed at user scope. A real
    # failure sets rc=1, which defers the destructive prune/uninstall legs
    # below, leaves the manifest unchanged, and propagates to the caller so
    # chezmoi retries this run_onchange on the next apply.
    if [[ -n "$installed_file" ]]; then
        local id
        for id in "${owned_ids[@]:-}"; do
            [[ -z "$id" ]] && continue
            if _user_installed "$id"; then
                continue
            fi
            echo "  Installing plugin (user scope): $id"
            claude plugin install "$id" >/dev/null 2>&1 || true
            if ! _user_installed "$id"; then
                echo "  WARN: 'claude plugin install $id' did not result in a user-scope install — run 'claude plugin install $id' by hand." >&2
                rc=1
            fi
        done
    fi

    # ── prune (manifest-owned marketplaces only) ───────────────────────────
    if [[ -f "$manifest" ]]; then
        while IFS= read -r _n; do [[ -n "$_n" ]] && prior_names+=("$_n"); done < "$manifest"
    fi

    # A missing cache means we cannot resolve that desired plugin's marketplace
    # name this run (it lives in the absent marketplace.json), so we cannot prove
    # which prior-manifest entry it owns. Defer all destructive prune / uninstall
    # until a run where every desired cache is present AND the prime is clean
    # (rc == 0); the manifest is retained (below) so nothing still-desired is
    # dropped. Gating on rc guards against a transiently failed `marketplace add`
    # removing a retired marketplace while the manifest rewrite is skipped.
    local m
    if (( any_missing == 0 && rc == 0 )); then
        for m in "${prior_names[@]:-}"; do
            [[ -z "$m" ]] && continue
            if ! _in "$m" "${owned_names[@]:-}"; then
                echo "  Removing retired marketplace: $m"
                claude plugin marketplace remove "$m" >/dev/null 2>&1 || rc=1
            fi
        done
    fi

    # ── uninstall retired user-scope plugins (manifest-owned marketplace) ─────
    # Never touch project-scope installs. Only uninstall when the plugin's
    # marketplace is manifest-proven ours AND the plugin is no longer desired.
    if [[ -n "$installed_file" && -f "$installed_file" ]]; then
        # Uninstall retired user-scope plugins — only on a fully-cached run, for
        # the same reason prune is deferred above (a missing cache hides the
        # ownership mapping).
        if (( any_missing == 0 && rc == 0 )); then
            local iid mkt plug
            while IFS= read -r iid; do
                [[ -z "$iid" ]] && continue
                mkt="${iid##*@}"; plug="${iid%@*}"
                _in "$mkt" "${prior_names[@]:-}" || continue    # marketplace we own
                _in "$plug" "${desired_keys[@]:-}" && continue  # plugin still desired
                echo "  Uninstalling retired plugin (user scope): $iid"
                claude plugin uninstall "$iid" --scope user >/dev/null 2>&1 || rc=1
            done < <(jq -r '.plugins | to_entries[] | select(.value | any(.scope == "user")) | .key' "$installed_file")
        fi

        # Project-scope installs are never touched; the read-only NOTE always
        # runs. A dead projectPath is surfaced with the exact hand-cleanup command.
        local pid ppath
        while IFS="$(printf '\t')" read -r pid ppath; do
            [[ -z "$pid" ]] && continue
            [[ -d "$ppath" ]] && continue
            echo "  NOTE: plugin '$pid' is installed at project scope but its projectPath no longer exists ($ppath); not touched. Remove by hand with:"
            echo "        claude plugin uninstall '$pid' --scope project"
        done < <(jq -r '.plugins | to_entries[] | .key as $k | .value[] | select(.scope == "project") | [$k, (.projectPath // "")] | @tsv' "$installed_file")
    fi

    # ── NOTE non-owned dead directory sources ──────────────────────────────
    # Never removed (ownership rule): only surfaced for manual cleanup.
    if [[ -f "$known_file" ]]; then
        local kn kp
        while IFS="$(printf '\t')" read -r kn kp; do
            [[ -z "$kn" ]] && continue
            _in "$kn" "${owned_names[@]:-}" && continue
            _in "$kn" "${prior_names[@]:-}" && continue
            [[ -d "$kp" ]] && continue
            echo "  NOTE: marketplace '$kn' is a directory source whose path no longer exists ($kp) and is not repo-owned — remove by hand with:"
            echo "        claude plugin marketplace remove '$kn'"
        done < <(jq -r 'to_entries[] | select(.value.source.source == "directory") | [.key, .value.source.path] | @tsv' "$known_file")
    fi

    # ── manifest rewrite ───────────────────────────────────────────────────
    if [[ $rc -eq 0 ]]; then
        mkdir -p "$(dirname "$manifest")"
        # Owned = primed this run; on a missing-cache run also retain the prior
        # manifest names so a still-desired-but-uncloned plugin keeps its record.
        local -a keep=(); local _k
        for _k in "${owned_names[@]:-}"; do [[ -n "$_k" ]] && keep+=("$_k"); done
        if (( any_missing == 1 )); then
            for _k in "${prior_names[@]:-}"; do [[ -n "$_k" ]] && keep+=("$_k"); done
        fi
        if [[ ${#keep[@]} -gt 0 ]]; then
            printf '%s\n' "${keep[@]}" | sort -u > "$manifest"
        else
            : > "$manifest"
        fi
    else
        echo "  WARN: one or more plugin marketplace operations failed; manifest left unchanged" >&2
    fi
    return $rc
}
