#!/usr/bin/env bash
# db-path.sh — shared session-analytics database path resolver.
sessions_db_path() {
    local db cache
    if [[ -n "${SESSIONS_DB:-}" ]]; then
        db="$SESSIONS_DB"
        [[ "$db" = /* ]] || db="$PWD/$db"
    else
        cache="${XDG_CACHE_HOME:-}"
        [[ "$cache" = /* ]] || cache="$HOME/.cache"
        db="$cache/dotfiles/session-analytics/sessions.duckdb"
    fi
    printf '%s\n' "$db"
}
