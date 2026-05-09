#!/usr/bin/env bash
# cheese-flair: weighted name generator + quote picker.
#
# Reads ~/.claude/reference/cheese-flair.md by default. Used by the
# SessionStart hook to inject a fresh sample each session, so the
# principal CLAUDE.md stays slim.
#
# Default name distribution (mode=weighted):
#   ~50% Cheese Lord  ~25% Big hitters  ~25% full bank (curated + generated)
#
# CLI:
#   bash cheese-flair.sh sample                 # name + 3 quotes (hook output)
#   bash cheese-flair.sh name [mode]            # mode = weighted|curated|generated|mixed|big-hitter
#   bash cheese-flair.sh quote [count]          # count defaults to 1
#
# Sourceable: `source cheese-flair.sh` exposes cheese_name, cheese_quote,
# cheese_quotes, cheese_sample, cheese_curated_name, cheese_generate_name,
# cheese_big_hitter.

set -uo pipefail

CHEESE_FLAIR_BANK="${CHEESE_FLAIR_BANK:-${HOME}/.claude/reference/cheese-flair.md}"

# Pick N distinct lines at random from stdin. Prefer GNU shuf; fall back
# to a Fisher-Yates shuffle in awk so the script works on macOS without
# coreutils installed.
_cheese_pick_n() {
    local n="${1:-1}"
    if command -v shuf >/dev/null 2>&1; then
        shuf -n "$n"
    else
        # awk's default srand() seeds from current second, so back-to-back
        # calls within the same script invocation collide. Seed from $RANDOM
        # explicitly — varies per call inside one bash process.
        awk -v n="$n" -v seed="$RANDOM" '
            BEGIN { srand(seed) }
            { lines[NR] = $0 }
            END {
                if (NR == 0) exit
                for (i = NR; i > 1; i--) {
                    j = int(rand() * i) + 1
                    tmp = lines[i]; lines[i] = lines[j]; lines[j] = tmp
                }
                limit = (n < NR) ? n : NR
                for (i = 1; i <= limit; i++) print lines[i]
            }
        '
    fi
}

_cheese_pick_one() {
    _cheese_pick_n 1
}

# Extract bullet-list items from a `## <name>` section (level 2 heading).
_cheese_extract_h2() {
    local section="## $1"
    awk -v section="$section" '
        $0 == section { in_section = 1; next }
        /^## / { in_section = 0 }
        in_section && /^- / { sub(/^- /, ""); print }
    ' "$CHEESE_FLAIR_BANK"
}

# Extract bullet-list items from a `### <name>` section (level 3 heading).
_cheese_extract_h3() {
    local section="### $1"
    awk -v section="$section" '
        $0 == section { in_section = 1; next }
        /^## / { in_section = 0 }
        /^### / { in_section = ($0 == section) }
        in_section && /^- / { sub(/^- /, ""); print }
    ' "$CHEESE_FLAIR_BANK"
}

cheese_curated_name() {
    _cheese_extract_h2 "Curated names" | _cheese_pick_one
}

cheese_big_hitter() {
    _cheese_extract_h2 "Big hitters" | _cheese_pick_one
}

cheese_generate_name() {
    local adj cheese title
    adj=$(_cheese_extract_h3 "Adjectives" | _cheese_pick_one)
    cheese=$(_cheese_extract_h3 "Cheeses" | _cheese_pick_one)
    title=$(_cheese_extract_h3 "Title formats" | _cheese_pick_one)
    printf '%s %s\n' "$adj" "${title//\{C\}/$cheese}"
}

_cheese_mixed_pick() {
    if (( RANDOM % 2 == 0 )); then
        cheese_curated_name
    else
        cheese_generate_name
    fi
}

# Weighted: 50% Cheese Lord, 25% big hitter, 25% full bank pull.
_cheese_weighted_pick() {
    local roll=$(( RANDOM % 100 ))
    if (( roll < 50 )); then
        printf 'Cheese Lord\n'
    elif (( roll < 75 )); then
        cheese_big_hitter
    else
        _cheese_mixed_pick
    fi
}

cheese_name() {
    local mode="${1:-weighted}"
    case "$mode" in
        weighted)   _cheese_weighted_pick ;;
        curated)    cheese_curated_name ;;
        generated)  cheese_generate_name ;;
        mixed)      _cheese_mixed_pick ;;
        big-hitter) cheese_big_hitter ;;
        *)
            printf 'cheese_name: unknown mode %q\n' "$mode" >&2
            return 1
            ;;
    esac
}

# Emit N "Universe — quote" lines (default 1, distinct within a single call).
cheese_quotes() {
    local count="${1:-1}"
    awk '
        /^## / {
            in_quotes = ($0 == "## Quotes")
            next
        }
        in_quotes && /^### / { universe = substr($0, 5); next }
        in_quotes && /^- / {
            sub(/^- /, "")
            printf "%s — %s\n", universe, $0
        }
    ' "$CHEESE_FLAIR_BANK" | _cheese_pick_n "$count"
}

cheese_quote() {
    cheese_quotes 1
}

cheese_sample() {
    printf '## Cheese flair (rotating each session)\n\n'
    printf -- '- Address: %s\n' "$(cheese_name)"
    printf -- '- Quotes:\n'
    cheese_quotes 3 | sed 's/^/  - /'
}

# CLI dispatcher
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-sample}" in
        sample) cheese_sample ;;
        name)   cheese_name "${2:-weighted}" ;;
        quote)  cheese_quotes "${2:-1}" ;;
        *)
            cat >&2 <<'USAGE'
Usage: cheese-flair {sample | name [weighted|curated|generated|mixed|big-hitter] | quote [count]}
USAGE
            exit 2
            ;;
    esac
fi
