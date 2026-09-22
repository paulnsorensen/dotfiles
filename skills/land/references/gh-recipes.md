# gh recipes for /land

Every command uses `gh` as the transport.
Use the host GitHub primitive first when one exists.
Replace `{o}/{r}` with the owner and repo from `gh repo view --json nameWithOwner --jq .nameWithOwner`.
Keep JSON extraction inside `--jq`; do not pipe into a separate `jq`.

## Resolve the PR

```bash
gh pr view <n> --json number,url,state,isDraft,headRefName,baseRefName,headRefOid,mergeStateStatus,reviewDecision
gh pr view --json number --jq .number            # PR of the current branch
gh pr checkout <n>
```

## CodeRabbit state

```bash
# Top-level bot comments, newest last
gh api "repos/{o}/{r}/issues/<n>/comments" --paginate \
  --jq '.[] | select(.user.login=="coderabbitai[bot]") | {id, created_at, body: .body[0:600]}'

# Bot reviews with the commit they cover
gh api "repos/{o}/{r}/pulls/<n>/reviews" --paginate \
  --jq '.[] | select(.user.login=="coderabbitai[bot]") | {id, state, submitted_at, commit_id, body: .body[0:300]}'

# Check runs on the head SHA (rate limit shows as a passing "Review rate limited" check)
gh api "repos/{o}/{r}/commits/<sha>/check-runs" --jq '.check_runs[] | {name, status, conclusion}'
```

Signals in the newest bot comment body:

| Body contains | Class |
|---|---|
| `rate limit` (any case), `Review rate limited` | `rate-limited` |
| `paused`, `Review skipped`, `auto-pause` | `paused` |
| `Actionable comments posted:` | `reviewed` |

Wait-time parse: `([0-9]+) minutes?` and `([0-9]+) seconds?` in the body. No match → 5 minutes.

## Request a review

```bash
gh pr comment <n> --body "@coderabbitai review"          # incremental
gh pr comment <n> --body "@coderabbitai full review"     # from scratch
gh pr comment <n> --body "@coderabbitai rate limit"      # remaining quota, costs no review
```

Wait for completion with a bounded poll. The poll accepts only a newer bot review or an actionable summary comment.

```bash
# TEST: review-completion-poll
REQUESTED_AT="${REQUESTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
for ((poll=1; poll<=40; poll++)); do
  if ! reviews="$(gh api "repos/{o}/{r}/pulls/<n>/reviews" --paginate \
      --jq '.[] | select(.user.login=="coderabbitai[bot]") | .submitted_at')"; then
    printf '%s\n' 'API error while polling reviews' >&2
    exit 1
  fi
  review_complete=false
  while IFS= read -r submitted_at; do
    if [[ "$submitted_at" > "$REQUESTED_AT" ]]; then
      review_complete=true
      break
    fi
  done <<< "$reviews"
  if [[ "$review_complete" != true ]]; then
    if ! summaries="$(gh api "repos/{o}/{r}/issues/<n>/comments" --paginate \
        --jq '.[] | select(.user.login=="coderabbitai[bot]" and (.body | test("Actionable comments posted:"; "i"))) | select(.body | test("rate limit"; "i") | not) | .created_at')"; then
      printf '%s\n' 'API error while polling comments' >&2
      exit 1
    fi
    while IFS= read -r created_at; do
      if [[ "$created_at" > "$REQUESTED_AT" ]]; then
        printf '%s\n' 'review completed'
        exit 0
      fi
    done <<< "$summaries"
  else
    printf '%s\n' 'review completed'
    exit 0
  fi
  if (( poll == 40 )); then
    printf '%s\n' 'review timed out' >&2
    exit 1
  fi
  sleep 30
done
```

## Open review threads (GraphQL)

The GraphQL request uses gh --paginate with the cursor variable and preserves the unresolved CodeRabbit filter.

```bash
# TEST: review-thread-pagination
if [[ "${INCLUDE_OUTDATED:-false}" == true ]]; then
  thread_filter='.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false and .comments.nodes[0].author.login=="coderabbitai")'
else
  thread_filter='.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false and .isOutdated==false and .comments.nodes[0].author.login=="coderabbitai")'
fi
thread_query='query($o:String!,$r:String!,$n:Int!,$endCursor:String){ repository(owner:$o,name:$r){ pullRequest(number:$n){ reviewThreads(first:100,after:$endCursor){ nodes{ id isResolved isOutdated path line comments(first:10){ nodes{ id databaseId author{login} body } } } pageInfo{ hasNextPage endCursor } } } } }'
if ! gh api graphql --paginate -f query="$thread_query" -f o={o} -f r={r} -F n=<n> \
    --jq "$thread_filter"; then
  printf '%s\n' 'API error while fetching review threads' >&2
  exit 1
fi
```

## Reply and resolve

```bash
# Reply in a thread; <comment-id> is the first comment's databaseId
gh api "repos/{o}/{r}/pulls/<n>/comments/<comment-id>/replies" -f body="Fixed in <sha> — <what>.

agent on behalf of <handle>"

# Resolve one thread; <thread-id> is the PRRT_… node id
gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -f id=<thread-id>
```

Resolve `<handle>` from `RESPOND_GH_HANDLE`, then `gh api user --jq .login`, then `git config user.name`.

## CI

```bash
gh pr checks <n> --watch --fail-fast
gh pr checks <n> --json name,bucket,link
gh run view <run-id> --log-failed
```

## Merge and watch

Select an allowed method before the no-merge stop. Set NO_MERGE=true for --no-merge. Set USE_AUTO=true for protected branches or merge queues. Bind the command to the validated head SHA.

```bash
# TEST: merge-command
HEAD_SHA="${HEAD_SHA:?set the validated head SHA}"
allowed_method="$(gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed \
  --jq 'if .squashMergeAllowed then "squash" elif .mergeCommitAllowed then "merge" elif .rebaseMergeAllowed then "rebase" else empty end')" || exit 1
case "$allowed_method" in squash|merge|rebase) ;;
  *) printf '%s\n' 'no supported merge method' >&2; exit 1 ;;
esac
merge_cmd=(gh pr merge <n> "--$allowed_method" --delete-branch --match-head-commit "$HEAD_SHA")
if [[ "${USE_AUTO:-false}" == true ]]; then
  merge_cmd+=(--auto)
fi
if [[ "${NO_MERGE:-false}" == true ]]; then
  printf 'merge command:'
  printf ' %q' "${merge_cmd[@]}"
  printf '\n'
  exit 0
fi
"${merge_cmd[@]}" || {
  printf '%s\n' 'merge command failed' >&2
  exit 1
}
```

Poll the merge state after the command.

```bash
# TEST: merge-watcher
for ((poll=1; poll<=60; poll++)); do
  if ! merge_state="$(gh pr view <n> --json state,mergedAt,mergeStateStatus \
      --jq '"\(.state) \(.mergeStateStatus)"')"; then
    printf '%s\n' 'API error while polling merge state' >&2
    exit 1
  fi
  printf '%s\n' "$merge_state"
  case "$merge_state" in
    MERGED*) exit 0 ;;
    CLOSED*) printf '%s\n' 'pull request closed' >&2; exit 1 ;;
    *' DIRTY') printf '%s\n' 'merge conflicts detected; route to /melt' >&2; exit 1 ;;
    *' BLOCKED') printf '%s\n' 'merge blocked by a requirement' >&2; exit 1 ;;
  esac
  if (( poll == 60 )); then
    printf '%s\n' 'merge timed out' >&2
    exit 1
  fi
  sleep 30
done
```

mergeStateStatus values: `CLEAN` means merge now; `BLOCKED` means a required check or review is missing; `DIRTY` means conflicts; `UNSTABLE` means a non-required check failed.
