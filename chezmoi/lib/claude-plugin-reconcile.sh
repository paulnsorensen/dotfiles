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

    # ── install desired plugins at user scope ────────────────────────────────
    # Enabling via settings.json does not populate installed_plugins.json; the
    # CLI must install. Idempotent: skip ids already user-installed; tolerate an
    # "already installed" nonzero exit without failing the reconcile.
    if [[ -n "$installed_file" ]]; then
        local id
        for id in "${owned_ids[@]:-}"; do
            [[ -z "$id" ]] && continue
            if [[ -f "$installed_file" ]] \
                && jq -e --arg id "$id" '(.plugins[$id] // []) | any(.scope == "user")' "$installed_file" >/dev/null 2>&1; then
                continue
            fi
            echo "  Installing plugin (user scope): $id"
            claude plugin install "$id" >/dev/null 2>&1 \
                || echo "  WARN: 'claude plugin install $id' failed (may already be installed) — left as-is." >&2
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
