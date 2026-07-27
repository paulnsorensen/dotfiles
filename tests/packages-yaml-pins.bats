#!/usr/bin/env bats
# Validate packages.yaml manifest pins: every npm/uv/cargo/gh-extension entry
# that stays outside mise carries an exact version:/rev: pin plus a Renovate
# custom-regex-manager annotation, exempting milknado by design.

DOTFILES_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
PACKAGES_YAML="$DOTFILES_DIR/packages/packages.yaml"

# entry_name:datasource — the 13 pinned entries and their expected Renovate datasource
PINNED_ENTRIES=(
    "vtsls:npm"
    "eslint:npm"
    "markdownlint-cli2:npm"
    "ccusage:npm"
    "agent-skills:npm"
    "graphite:npm"
    "ralphify:pypi"
    "ruff:pypi"
    "check-jsonschema:pypi"
    "skills-ref:git-refs"
    "tavily-cli:pypi"
    "gh-stack:github-releases"
    "cargo-update:crate"
)

@test "packages.yaml is valid YAML after adding pins" {
    run yq eval '.' "$PACKAGES_YAML"
    [[ $status -eq 0 ]]
}

@test "each of the 13 pinned entries has a version or rev key" {
    for pair in "${PINNED_ENTRIES[@]}"; do
        local name="${pair%%:*}"
        local version rev
        version=$(yq -r ".packages[] | select(kind == \"map\") | select(has(\"$name\")) | .\"$name\".version // \"\"" "$PACKAGES_YAML")
        rev=$(yq -r ".packages[] | select(kind == \"map\") | select(has(\"$name\")) | .\"$name\".rev // \"\"" "$PACKAGES_YAML")
        if [[ -z "$version" && -z "$rev" ]]; then
            echo "$name has neither a version: nor a rev: key" >&2
            return 1
        fi
    done
}

@test "pinned version/rev values are exact — no latest, no bare partial, no range" {
    for pair in "${PINNED_ENTRIES[@]}"; do
        local name="${pair%%:*}"
        local value
        value=$(yq -r ".packages[] | select(kind == \"map\") | select(has(\"$name\")) | (.\"$name\".version // .\"$name\".rev)" "$PACKAGES_YAML")
        if [[ -z "$value" ]]; then
            echo "$name has an empty version/rev value" >&2
            return 1
        fi
        if [[ "$value" == "latest" ]]; then
            echo "$name pin '$value' is 'latest', not exact" >&2
            return 1
        fi
        if [[ "$value" == *'^'* ]]; then
            echo "$name pin '$value' is a caret range, not exact" >&2
            return 1
        fi
        if [[ "$value" == *'~'* ]]; then
            echo "$name pin '$value' is a tilde range, not exact" >&2
            return 1
        fi
        # a bare partial like "8" (no dot) is a floating major, not exact
        if [[ "$value" != v* && "$value" != *.* && "$value" =~ ^[0-9]+$ ]]; then
            echo "$name pin '$value' looks like a bare floating partial, not an exact version" >&2
            return 1
        fi
    done
}

@test "skills-ref rev is a full 40-character git commit SHA, not a branch or ref name" {
    local rev
    rev=$(yq -r '.packages[] | select(kind == "map") | select(has("skills-ref")) | ."skills-ref".rev // ""' "$PACKAGES_YAML")
    if [[ ! "$rev" =~ ^[0-9a-f]{40}$ ]]; then
        echo "skills-ref rev '$rev' is not a full 40-character commit SHA (e.g. a branch name like 'main' would slip past a generic exactness check)" >&2
        return 1
    fi
}

@test "eslint's pkg field stays bare — version pin lives only in version:" {
    local pkg
    pkg=$(yq -r '.packages[] | select(kind == "map") | select(has("eslint")) | .eslint.pkg // ""' "$PACKAGES_YAML")
    [[ -z "$pkg" ]]
}

@test "each of the 13 pinned entries has an adjacent renovate annotation with a valid datasource" {
    for pair in "${PINNED_ENTRIES[@]}"; do
        local name="${pair%%:*}"
        local expected_ds="${pair##*:}"
        # the line above the entry's `- name:` line must carry the renovate annotation
        local entry_line annotation
        entry_line=$(grep -n "^  - ${name}:" "$PACKAGES_YAML" | head -1 | cut -d: -f1)
        if [[ -z "$entry_line" ]]; then
            echo "$name: entry line not found" >&2
            return 1
        fi
        annotation=$(sed -n "$((entry_line - 1))p" "$PACKAGES_YAML")
        if [[ "$annotation" != *"# renovate: datasource=${expected_ds} depName="* ]]; then
            echo "$name: expected line above '- ${name}:' to carry '# renovate: datasource=${expected_ds} depName=...', got: $annotation" >&2
            return 1
        fi
    done
}

@test "milknado stays exempt — no version, no rev, no renovate annotation" {
    local version rev entry_line annotation
    version=$(yq -r '.packages[] | select(kind == "map") | select(has("milknado")) | .milknado.version // ""' "$PACKAGES_YAML")
    rev=$(yq -r '.packages[] | select(kind == "map") | select(has("milknado")) | .milknado.rev // ""' "$PACKAGES_YAML")
    if [[ -n "$version" ]]; then
        echo "milknado unexpectedly has a version: $version" >&2
        return 1
    fi
    if [[ -n "$rev" ]]; then
        echo "milknado unexpectedly has a rev: $rev" >&2
        return 1
    fi
    entry_line=$(grep -n "^  - milknado:" "$PACKAGES_YAML" | head -1 | cut -d: -f1)
    if [[ -z "$entry_line" ]]; then
        echo "milknado entry not found" >&2
        return 1
    fi
    annotation=$(sed -n "$((entry_line - 1))p" "$PACKAGES_YAML")
    if [[ "$annotation" == *"# renovate:"* ]]; then
        echo "milknado unexpectedly has a renovate annotation: $annotation" >&2
        return 1
    fi
}

@test "rtk and cargo-llvm-cov cargo installer entries are absent after mise migration" {
    local name count
    for name in rtk cargo-llvm-cov; do
        count=$(yq -r ".packages[] | select(kind == \"map\") | select(has(\"$name\")) | .\"$name\"" "$PACKAGES_YAML" | wc -l | tr -d ' ')
        if [[ "$count" != "0" ]]; then
            echo "$name still has a packages.yaml installer entry" >&2
            return 1
        fi
    done
}
