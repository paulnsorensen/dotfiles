#!/usr/bin/env bash
# Greedy longest-processing-time bin packing for splitting the bats suite
# across CI shards. Weights come from tests/shard-weights.tsv; see that
# file's header for what the numbers mean and how stale entries are handled.

# shard_files INDEX TOTAL WEIGHTS_FILE FILE...
# Prints, one per line, the files assigned to shard INDEX (1-based) of
# TOTAL, using descending-weight bin packing (files sorted heaviest first,
# each assigned to the currently lightest bin; ties broken by name then by
# lowest bin index).
shard_files() {
    local index="$1" total="$2" weights_file="$3"
    shift 3

    if ! [[ "$total" =~ ^[0-9]+$ ]] || (( total < 1 )); then
        echo "shard_files: total must be an integer >= 1, got '$total'" >&2
        return 1
    fi
    if ! [[ "$index" =~ ^[0-9]+$ ]] || (( index < 1 || index > total )); then
        echo "shard_files: index must be an integer in 1..$total, got '$index'" >&2
        return 1
    fi

    local -A weight_of=()
    local -a all_weights=()
    if [[ -f "$weights_file" ]]; then
        local name weight
        while IFS=$'\t' read -r name weight; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            weight_of["$name"]="$weight"
            all_weights+=("$weight")
        done < "$weights_file"
    fi

    local median
    median="$(_shard_median "${all_weights[@]}")"

    local -a pairs=()
    local f base w
    for f in "$@"; do
        base="${f##*/}"
        w="${weight_of[$base]:-$median}"
        pairs+=("$w"$'\t'"$f")
    done

    local -a sorted=()
    if (( ${#pairs[@]} > 0 )); then
        while IFS=$'\t' read -r w f; do
            sorted+=("$w"$'\t'"$f")
        done < <(printf '%s\n' "${pairs[@]}" | sort -t $'\t' -k1,1rn -k2,2)
    fi

    local -a bin_sum=()
    local i
    for ((i = 1; i <= total; i++)); do
        bin_sum[i]=0
    done

    local entry target_bin target_sum
    for entry in "${sorted[@]}"; do
        w="${entry%%$'\t'*}"
        f="${entry#*$'\t'}"

        target_bin=1
        target_sum="${bin_sum[1]}"
        for ((i = 2; i <= total; i++)); do
            if _shard_lt "${bin_sum[i]}" "$target_sum"; then
                target_bin=$i
                target_sum="${bin_sum[i]}"
            fi
        done

        bin_sum[target_bin]="$(_shard_add "${bin_sum[target_bin]}" "$w")"
        if (( target_bin == index )); then
            printf '%s\n' "$f"
        fi
    done
}

# _shard_median W...  -> prints the median of the given numeric weights,
# or 0 when none are given.
_shard_median() {
    if (( $# == 0 )); then
        printf '0'
        return
    fi
    printf '%s\n' "$@" | sort -n | awk '
        { a[NR] = $1 }
        END {
            if (NR % 2 == 1) print a[(NR + 1) / 2]
            else print (a[NR / 2] + a[NR / 2 + 1]) / 2
        }'
}

# _shard_lt A B  -> true when the float A is less than the float B.
_shard_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# _shard_add A B  -> prints the float sum of A and B.
_shard_add() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.10g", a + b }'
}
