#!/usr/bin/env bats

@test "cheese flair finds bank beside library under arbitrary harness root" {
    local root="$BATS_TEST_TMPDIR/.amp"
    local home="$BATS_TEST_TMPDIR/home"
    mkdir -p "$root/lib" "$root/reference" "$home"
    cp "$BATS_TEST_DIRNAME/../agents/lib/cheese-flair.sh" "$root/lib/"
    cp "$BATS_TEST_DIRNAME/../agents/reference/cheese-flair.md" "$root/reference/"
    run env -u CHEESE_FLAIR_BANK HOME="$home" bash "$root/lib/cheese-flair.sh" quote 1
    [ "$status" -eq 0 ]
    [[ "$output" == *" — "* ]]
}
