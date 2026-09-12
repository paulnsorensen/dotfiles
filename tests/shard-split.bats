#!/usr/bin/env bats
#
# Regression tests for tests/lib/shard.sh's shard_files bin packing.
#
# Strategy: source the library directly and exercise shard_files against
# small fixture file lists and weights files under BATS_TEST_TMPDIR, so
# the packing behaviour is asserted without touching the real bats suite.

load test_helper

setup() {
    source "$REAL_DOTFILES_DIR/tests/lib/shard.sh"
    WEIGHTS="$BATS_TEST_TMPDIR/weights.tsv"
}

union_of_shards() {
    local total="$1" weights="$2"
    shift 2
    local i
    for ((i = 1; i <= total; i++)); do
        shard_files "$i" "$total" "$weights" "$@"
    done
}

@test "shard_files: union over shards 1..1 equals the input set" {
    printf 'a.bats\t1\nb.bats\t2\nc.bats\t3\n' > "$WEIGHTS"
    run union_of_shards 1 "$WEIGHTS" a.bats b.bats c.bats
    [ "$status" -eq 0 ]
    sorted_output="$(printf '%s\n' "${lines[@]}" | sort)"
    expected="$(printf '%s\n' a.bats b.bats c.bats | sort)"
    [ "$sorted_output" = "$expected" ]
    [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq 3 ]
}

@test "shard_files: union over shards 1..4 equals the input set, no dupes" {
    printf 'a.bats\t1\nb.bats\t2\nc.bats\t3\nd.bats\t4\ne.bats\t5\nf.bats\t6\n' > "$WEIGHTS"
    run union_of_shards 4 "$WEIGHTS" a.bats b.bats c.bats d.bats e.bats f.bats
    [ "$status" -eq 0 ]
    sorted_output="$(printf '%s\n' "${lines[@]}" | sort)"
    expected="$(printf '%s\n' a.bats b.bats c.bats d.bats e.bats f.bats | sort)"
    [ "$sorted_output" = "$expected" ]
    [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq 6 ]
}

@test "shard_files: N exceeding the file count still covers every file once" {
    printf 'a.bats\t1\nb.bats\t2\nc.bats\t3\n' > "$WEIGHTS"
    run union_of_shards 10 "$WEIGHTS" a.bats b.bats c.bats
    [ "$status" -eq 0 ]
    sorted_output="$(printf '%s\n' "${lines[@]}" | sort)"
    expected="$(printf '%s\n' a.bats b.bats c.bats | sort)"
    [ "$sorted_output" = "$expected" ]
    [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l)" -eq 3 ]
}

@test "shard_files: a file heavier than the ideal bin still terminates alone-enough" {
    printf 'heavy.bats\t100\nx.bats\t1\ny.bats\t1\nz.bats\t1\n' > "$WEIGHTS"
    run shard_files 1 2 "$WEIGHTS" heavy.bats x.bats y.bats z.bats
    [ "$status" -eq 0 ]
    shard1="$output"
    run shard_files 2 2 "$WEIGHTS" heavy.bats x.bats y.bats z.bats
    [ "$status" -eq 0 ]
    shard2="$output"

    heavy_count=$(printf '%s\n%s\n' "$shard1" "$shard2" | grep -c '^heavy\.bats$')
    [ "$heavy_count" -eq 1 ]
}

@test "shard_files: an unlisted file falls back to the median weight" {
    # median(6, 5, 1) = 5, tying unlisted c.bats with b.bats and sorting it
    # right after b.bats (name tie-break) -- landing it in b.bats's bin.
    printf 'a.bats\t6\nb.bats\t5\nd.bats\t1\n' > "$WEIGHTS"
    run shard_files 1 2 "$WEIGHTS" a.bats b.bats c.bats d.bats
    [ "$status" -eq 0 ]
    median_shard="$output"
    [[ "$median_shard" != *"c.bats"* ]]

    # Pinning c.bats to weight 0 instead sorts it dead last, after the bin
    # sums have already diverged -- landing it in a.bats's bin instead.
    WEIGHTS_ZERO="$BATS_TEST_TMPDIR/weights-zero.tsv"
    printf 'a.bats\t6\nb.bats\t5\nd.bats\t1\nc.bats\t0\n' > "$WEIGHTS_ZERO"
    run shard_files 1 2 "$WEIGHTS_ZERO" a.bats b.bats c.bats d.bats
    [ "$status" -eq 0 ]
    zero_shard="$output"
    [[ "$zero_shard" == *"c.bats"* ]]

    [ "$median_shard" != "$zero_shard" ]
}

@test "shard_files: rejects index 0" {
    printf 'a.bats\t1\n' > "$WEIGHTS"
    run shard_files 0 4 "$WEIGHTS" a.bats
    [ "$status" -ne 0 ]
}

@test "shard_files: rejects index greater than total" {
    printf 'a.bats\t1\n' > "$WEIGHTS"
    run shard_files 5 4 "$WEIGHTS" a.bats
    [ "$status" -ne 0 ]
}

@test "shard_files: rejects total 0" {
    printf 'a.bats\t1\n' > "$WEIGHTS"
    run shard_files 1 0 "$WEIGHTS" a.bats
    [ "$status" -ne 0 ]
}

@test "shard_files: rejects a non-integer index" {
    printf 'a.bats\t1\n' > "$WEIGHTS"
    run shard_files abc 4 "$WEIGHTS" a.bats
    [ "$status" -ne 0 ]
}
