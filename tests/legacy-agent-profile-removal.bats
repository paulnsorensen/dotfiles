#!/usr/bin/env bats

load test_helper

@test "the removed profile engine paths are absent" {
    local root="$BATS_TEST_DIRNAME/.."
    local legacy_command="a""p"
    local legacy_tree="agent""-""profile"
    local installer="$root/chezmoi/.chezmoiscripts/run_onchange_after_install-${legacy_tree}.sh.tmpl"

    [[ ! -e "$root/$legacy_tree" ]]
    [[ ! -e "$root/bin/$legacy_command" ]]
    [[ ! -e "$installer" ]]
}

@test "live profile surfaces contain no removed engine references" {
    local root="$BATS_TEST_DIRNAME/.."
    local legacy_command="a""p"
    local legacy_module="agent""_""profile"
    local legacy_tree="agent""-""profile"
    local legacy_paths="${legacy_tree}/|/${legacy_tree}([/\"'[:space:]]|$)|bin/${legacy_command}([[:space:]/]|$)"
    local legacy_invocation="(^|[^[:alnum:]_-])${legacy_command}[[:space:]]+(path|fetch-sources|install|_install-internal|uninstall|copilot-flags|profile|ls|show|render|apply|exec|perms|ingest|describe|check)([[:space:]]|$)"
    local legacy_possessive="(^|[^[:alnum:]_-])${legacy_command}(['’]s)"
    local legacy_binary="(^|[^[:alnum:]_-])${legacy_tree}[[:space:]]+check([[:space:]]|$)"
    local legacy_ref="${legacy_invocation}|${legacy_possessive}|${legacy_binary}|${legacy_module}|${legacy_paths}"
    local architecture="$root/.hallouminate/wiki/architecture/agent""-""profile.md"
    local cross_harness="$root/.hallouminate/wiki/architecture/cross-harness-plugins.md"

    run grep -rInE \
        --exclude-dir=.git \
        --exclude-dir=.cheese \
        --exclude-dir=.worktrees \
        --exclude-dir=.hallouminate \
        --exclude-dir=.serena \
        --exclude-dir=.ruff_cache \
        --exclude-dir=.pytest_cache \
        --exclude-dir=.code-review-graph \
        --exclude-dir=.claude \
        --exclude-dir=.emdash \
        --exclude-dir=.conductor \
        --exclude-dir=.scratch \
        --exclude-dir=archive \
        --exclude-dir=docs \
        --exclude-dir=reference \
        --exclude-dir=__pycache__ \
        --exclude='run_once_before_migrate-*' \
        -- "$legacy_ref" "$root"
    [[ "$status" -eq 1 ]] || {
        echo "live profile scan must exit 1 when grep finds no retired reference (status=$status): $output" >&2
        return 1
    }

    run grep -nE -- "$legacy_ref" "$architecture" "$cross_harness"
    [[ "$status" -eq 1 ]] || {
        echo "architecture/cross-harness scan must exit 1 when grep finds no retired reference (status=$status): $output" >&2
        return 1
    }
}

@test "the package registry has no retired profile engine map" {
    local root="$BATS_TEST_DIRNAME/.."
    local package_map="$root/packages/packages.yaml"
    local legacy_tree="agent""-""profile"

    # Parse YAML nodes rather than scanning comments/text: a retired package
    # key or value must not survive in any package-map shape.
    run yq -e -r '
        .. | select(tag == "!!str")
           | select(test("(^|[^[:alnum:]])agent[-_]profile([^[:alnum:]]|$)"))
    ' "$package_map"
    [[ "$status" -eq 1 ]] || {
        echo "package map contains a retired ${legacy_tree} node (status=$status): $output" >&2
        return 1
    }
}

@test "retired profile command cannot return through aliases or dispatch" {
    local root="$BATS_TEST_DIRNAME/.."
    local legacy_command="a""p"
    local legacy_aliases="(^|[^[:alnum:]_])alias[[:space:]]+${legacy_command}([[:space:]=]|$)|(^|[^[:alnum:]_])function[[:space:]]+${legacy_command}([[:space:](]|$)|(^|[^[:alnum:]_])${legacy_command}[[:space:]]*\\([[:space:]]*\\{"
    local legacy_dispatch="(^|[[:space:]|;&])${legacy_command}[[:space:]]*[\"']?[[:space:]]*(\\)|\\||&&|;)"
    local retired_profile_verbs="(path|fetch-sources|install|_install-internal|uninstall|copilot-flags|profile|ls|show|render|exec|perms|sync|run|delete|remove)"
    local retired_profile_spellings="(^|[^[:alnum:]_-])(cheese|dots)[[:space:]]+profile[[:space:]]+${retired_profile_verbs}([[:space:]]|$)"
    local legacy_ref="${legacy_aliases}|${legacy_dispatch}|${retired_profile_spellings}"

    run grep -rInE \
        --exclude-dir=.git \
        --exclude-dir=.cheese \
        --exclude-dir=.worktrees \
        --exclude-dir=.hallouminate \
        --exclude-dir=.serena \
        --exclude-dir=.ruff_cache \
        --exclude-dir=.pytest_cache \
        --exclude-dir=.code-review-graph \
        --exclude-dir=.claude \
        --exclude-dir=.emdash \
        --exclude-dir=.conductor \
        --exclude-dir=.scratch \
        --exclude-dir=archive \
        --exclude-dir=docs \
        --exclude-dir=reference \
        --exclude-dir=__pycache__ \
        --exclude='run_once_before_migrate-*' \
        --exclude='migrate-ap-claude.bats' \
        --exclude='claude-plugin-reconcile.bats' \
        --exclude='chezmoi-wiring.bats' \
        --exclude='claude-settings.bats' \
        --exclude='skills-external.bats' \
        -- "$legacy_ref" "$root"
    [[ "$status" -eq 1 ]] || {
        echo "retired profile alias/dispatch/spelling found (status=$status): $output" >&2
        return 1
    }

    run grep -nE -- "$legacy_ref" \
        "$root/.hallouminate/wiki/architecture/agent""-""profile.md" \
        "$root/.hallouminate/wiki/architecture/cross-harness-plugins.md"
    [[ "$status" -eq 1 ]] || {
        echo "retired profile alias/dispatch/spelling found in architecture docs (status=$status): $output" >&2
        return 1
    }
}
