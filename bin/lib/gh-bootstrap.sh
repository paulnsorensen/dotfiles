# shellcheck shell=bash
# gh-bootstrap.sh — repo-policy helpers, sourced by bin/gh-bootstrap.
#
# Mined from the retired /gh-bootstrap skill: squash-only merge defaults, a
# default-branch ruleset, and release-notes scaffolding. Functions only — no
# top-level side effects, so sourcing is safe from bats tests.

GHB_RULESET_NAME="main: PR + CI"

# Echo the merge-default fields of a repo as one JSON object.
ghb_merge_state() {
    gh api "repos/$1" --jq '{
        squash: .allow_squash_merge, merge: .allow_merge_commit,
        rebase: .allow_rebase_merge, auto: .allow_auto_merge,
        delete: .delete_branch_on_merge,
        title: .squash_merge_commit_title, body: .squash_merge_commit_message
    }'
}

# Make squash the only merge button. The PR title becomes the commit subject
# and the PR body the commit body, so `git log` on main lists merged PRs.
# The API treats a PATCH with unchanged values as a no-op.
ghb_apply_merge_defaults() {
    gh api -X PATCH "repos/$1" \
        -F allow_squash_merge=true \
        -F allow_merge_commit=false \
        -F allow_rebase_merge=false \
        -F allow_auto_merge=true \
        -F delete_branch_on_merge=true \
        -f squash_merge_commit_title=PR_TITLE \
        -f squash_merge_commit_message=PR_BODY >/dev/null
}

# Render the default-branch ruleset JSON on stdout.
# Usage: ghb_render_ruleset <reviews> <queue:0|1> <check>...
# Rules: no deletion, no force-push, PR required (squash only), named checks
# must pass. queue=1 adds a squash merge queue. A merge queue needs a public
# repo or a Team/Enterprise plan.
ghb_render_ruleset() {
    local reviews="$1" queue="$2"
    shift 2
    (($# > 0)) || { echo "ghb_render_ruleset: at least one check name is required" >&2; return 1; }
    [[ "$reviews" =~ ^[0-9]+$ ]] || { echo "ghb_render_ruleset: reviews must be a non-negative integer" >&2; return 1; }
    local team=false
    ((reviews > 0)) && team=true
    jq -n --arg name "$GHB_RULESET_NAME" --argjson reviews "$reviews" \
        --argjson queue "$([[ "$queue" == 1 ]] && echo true || echo false)" \
        --argjson team "$team" \
        --args '{
        name: $name,
        target: "branch",
        enforcement: "active",
        conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
        bypass_actors: [],
        rules: ([
            {type: "deletion"},
            {type: "non_fast_forward"},
            {type: "pull_request", parameters: {
                required_approving_review_count: $reviews,
                dismiss_stale_reviews_on_push: $team,
                require_code_owner_review: false,
                require_last_push_approval: false,
                required_review_thread_resolution: $team,
                allowed_merge_methods: ["squash"]}},
            {type: "required_status_checks", parameters: {
                strict_required_status_checks_policy: false,
                do_not_enforce_on_create: false,
                required_status_checks: [$ARGS.positional[] | {context: .}]}}
        ] + (if $queue then [{type: "merge_queue", parameters: {
                check_response_timeout_minutes: 60,
                grouping_strategy: "ALLGREEN",
                max_entries_to_build: 5,
                max_entries_to_merge: 5,
                min_entries_to_merge: 1,
                min_entries_to_merge_wait_minutes: 5,
                merge_method: "SQUASH"}}] else [] end))
    }' "$@"
}

# Create or update the ruleset by name, so a re-run never duplicates it.
# Usage: ghb_upsert_ruleset <repo> <ruleset-json-file>
# Echoes "created" or "updated <id>".
ghb_upsert_ruleset() {
    local repo="$1" file="$2" id list
    list=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$GHB_RULESET_NAME\") | .id") || return 1
    id=$(head -n1 <<<"$list")
    if [[ -n "$id" ]]; then
        gh api -X PUT "repos/$repo/rulesets/$id" --input "$file" >/dev/null || return 1
        echo "updated $id"
    else
        gh api -X POST "repos/$repo/rulesets" --input "$file" >/dev/null || return 1
        echo "created"
    fi
}

# Warn when a merge queue may be unavailable (private repo, no Team/
# Enterprise plan) and remind about the merge_group CI trigger. Call before
# a queue ruleset POST/PUT (--queue only). Non-fatal: the API call itself is
# authoritative on whether the plan actually supports a queue.
ghb_queue_precheck() {
    local repo="$1" visibility
    if ! visibility=$(gh api "repos/$repo" --jq .visibility); then
        echo "gh-bootstrap: could not check $repo's visibility; skipping the merge-queue precheck" >&2
        return 0
    fi
    if [[ "$visibility" != "public" ]]; then
        echo "gh-bootstrap: $repo is $visibility; a merge queue needs a public repo or a Team/Enterprise plan" >&2
    fi
    echo "gh-bootstrap: reminder — required-check workflows need 'on: merge_group' to run in the merge queue" >&2
}

# List the check-run names on the default-branch head. Required checks must
# match these names exactly; the Actions UI and workflow `name:` often differ.
ghb_check_names() {
    local repo="$1" branch sha
    branch=$(gh api "repos/$repo" --jq .default_branch) || return 1
    sha=$(gh api "repos/$repo/commits/$branch" --jq .sha) || return 1
    gh api "repos/$repo/commits/$sha/check-runs" --jq '.check_runs[].name' | sort -u
}

# Write a scaffold file only when it is absent or already identical.
# Usage: ghb_scaffold <dest> <render-function>
# Echoes created / unchanged; on a difference it prints the diff and returns 2
# so the caller never clobbers local edits.
ghb_scaffold() {
    local dest="$1" render="$2" tmp rc=0
    tmp=$(mktemp) || return 1
    "$render" >"$tmp" || { rm -f "$tmp"; return 1; }
    if [[ ! -e "$dest" ]]; then
        if ! mkdir -p "$(dirname "$dest")" || ! mv "$tmp" "$dest"; then
            rm -f "$tmp"
            return 1
        fi
        echo "created $dest"
        return 0
    fi
    if cmp -s "$tmp" "$dest"; then
        echo "unchanged $dest"
    else
        echo "differs $dest (left as is):"
        diff -u "$dest" "$tmp" || true
        rc=2
    fi
    rm -f "$tmp"
    return "$rc"
}

# Labels that ghb_render_release_notes buckets on. `enhancement` and `bug`
# exist on every new repo.
# shellcheck disable=SC2034  # read by bin/gh-bootstrap
GHB_RELEASE_LABELS=(breaking-change feature fix docs dependencies chore refactor ci build test ignore-for-release skip-changelog)

# .github/release.yml: auto-generated release notes, grouped by PR label.
# Used by `gh release create --generate-notes` and the web "Generate" button.
ghb_render_release_notes() {
    cat <<'YAML'
# Auto-generated release notes, grouped by PR label.
# https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes
changelog:
  exclude:
    labels: [ignore-for-release, skip-changelog]
    authors: [dependabot, github-actions, renovate]
  categories:
    - title: Breaking changes
      labels: [breaking-change, breaking]
    - title: Features
      labels: [enhancement, feature]
    - title: Fixes
      labels: [bug, bugfix, fix]
    - title: Documentation
      labels: [documentation, docs]
    - title: Dependencies
      labels: [dependencies]
    - title: Internal
      labels: [chore, refactor, ci, build, test]
    - title: Other changes
      labels: ["*"]
YAML
}

# .github/workflows/release.yml: a `v*` tag push publishes a release with
# generated notes. It refuses a tag that is not on the default branch, so
# only reviewed code ships. cancel-in-progress stays false so quick
# successive tags all publish. Refresh the pinned checkout SHA with:
#   gh api repos/actions/checkout/git/refs/tags/<tag> --jq .object.sha
ghb_render_release_workflow() {
    cat <<'YAML'
name: release

on:
  push:
    tags:
      - "v[0-9]*"

permissions:
  contents: write

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  release:
    name: publish github release
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 0

      - name: Verify tag is on the default branch
        env:
          DEFAULT_BRANCH: ${{ github.event.repository.default_branch }}
        run: |
          set -euo pipefail
          git fetch origin "$DEFAULT_BRANCH"
          if ! git merge-base --is-ancestor "$GITHUB_SHA" "origin/$DEFAULT_BRANCH"; then
            echo "::error::Tag ${GITHUB_REF_NAME} is not on origin/$DEFAULT_BRANCH. Refusing to publish."
            exit 1
          fi

      - name: Create release with generated notes
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ github.ref_name }}
        run: gh release create "$TAG" --title "$TAG" --generate-notes --verify-tag
YAML
}
