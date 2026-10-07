# gh recipes for /land

Every command uses `gh` as transport. Replace `{o}/{r}` with `gh repo view --json nameWithOwner --jq .nameWithOwner`.
Use the host GitHub primitive when available. Keep JSON extraction in `--jq`.

## Resolve and inventory

```bash
gh pr view <n> --json number,url,state,mergedAt,mergeCommit,isDraft,headRefName,baseRefName,headRefOid,mergeStateStatus,reviewDecision
gh pr view --json number --jq .number
gh pr checkout <n>
```

Fetch complete bodies and every page. REST uses `user.type`; some integrations expose only a `[bot]` login.
Do not let a CodeRabbit zero-comment summary suppress another bot's findings.

```bash
# TEST: all-bot-inventory
if ! issue_comments="$(gh api "repos/{o}/{r}/issues/<n>/comments" --paginate \
    --jq '.[] | select(.user.type=="Bot" or (.user.login | endswith("[bot]"))) | {id, updated_at, html_url, login: .user.login, body}')"; then
  printf '%s\n' 'API error while fetching issue comments' >&2
  exit 1
fi
if ! reviews="$(gh api "repos/{o}/{r}/pulls/<n>/reviews" --paginate \
    --jq '.[] | select(.user.type=="Bot" or (.user.login | endswith("[bot]"))) | {id, submitted_at, commit_id, html_url, login: .user.login, body}')"; then
  printf '%s\n' 'API error while fetching reviews' >&2
  exit 1
fi
printf '%s\n' "$issue_comments" "$reviews"
```

GraphQL threads can contain comments from several authors. Inspect every comment, not only the first author.
`gh api graphql --paginate` follows `pageInfo.endCursor` through all threads. Filter bot authors after all pages.

```bash
# TEST: review-thread-pagination
thread_query='query($o:String!,$r:String!,$n:Int!,$endCursor:String){ repository(owner:$o,name:$r){ pullRequest(number:$n){ reviewThreads(first:100,after:$endCursor){ nodes{ id isResolved isOutdated path line comments(first:100){ nodes{ id databaseId url updatedAt author{ __typename login } body } pageInfo{ hasNextPage endCursor } } } pageInfo{ hasNextPage endCursor } } } } }'
if ! gh api graphql --paginate -f query="$thread_query" -f o={o} -f r={r} -F n=<n> \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]'; then
  printf '%s\n' 'API error while fetching review threads' >&2
  exit 1
fi
```

For a thread whose comments have `hasNextPage == true`, fetch its remaining comments before triage.
Repeat for every such thread. Never treat the first 100 comments as the full thread.

```bash
thread_comments='query($id:ID!,$endCursor:String){ node(id:$id){ ... on PullRequestReviewThread { comments(first:100,after:$endCursor){ nodes{ id databaseId url updatedAt author{ __typename login } body } pageInfo{ hasNextPage endCursor } } } } }'
gh api graphql --paginate -f query="$thread_comments" -f id=<thread-id> \
  --jq '.data.node.comments.nodes[] | select(.author.__typename=="Bot")'
```

Skip outdated threads by default, but record their IDs. Include them with `--include-outdated`.
Record source ID, body, updated time, and disposition. Check existing agent replies before posting.
Notices and duplicates need a recorded reason, not another PR comment.

## Conditional review

Read CodeRabbit signals only when CodeRabbit participates. Its `Review rate limited` check is not a review.
A paused or rate-limited CodeRabbit may need a request. No other bot has a universal review command.

```bash
gh api "repos/{o}/{r}/commits/<sha>/check-runs" --jq '.check_runs[] | {name, status, conclusion}'
gh pr comment <n> --body "@coderabbitai review"
gh pr comment <n> --body "@coderabbitai full review"
gh pr comment <n> --body "@coderabbitai rate limit"
```

CodeRabbit signals in its newest comment: `rate limit` means wait; `paused`, `Review skipped`, or `auto-pause` means request a review.
Parse `([0-9]+) minutes?` and `([0-9]+) seconds?` for the wait. If absent, use five minutes; cap at 60 minutes.
Set `REQUESTED_AT` just before posting. Wait for a review on the validated SHA.
A newer summary is a signal to refetch reviews, not proof of SHA coverage.

```bash
# TEST: review-completion-poll
REQUESTED_AT="${REQUESTED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
HEAD_SHA="${HEAD_SHA:?set validated head SHA}"
for ((poll=1; poll<=40; poll++)); do
  if ! reviews="$(gh api "repos/{o}/{r}/pulls/<n>/reviews" --paginate \
      --jq '.[] | select(.user.type=="Bot" or (.user.login | endswith("[bot]"))) | select(.user.login=="coderabbitai[bot]") | "\(.submitted_at) \(.commit_id)"')"; then
    printf '%s\n' 'API error while polling reviews' >&2
    exit 1
  fi
  while read -r submitted_at reviewed_sha; do
    if [[ "$submitted_at" > "$REQUESTED_AT" && "$reviewed_sha" == "$HEAD_SHA" ]]; then
      printf '%s\n' 'review completed for validated head'
      exit 0
    fi
  done <<< "$reviews"
  if (( poll == 40 )); then
    printf '%s\n' 'review timed out or covered another SHA' >&2
    exit 1
  fi
  sleep 30
done
```

## Reply and resolve

Reply to actionable inline findings in the thread. Use a linked PR comment for issue comments or review bodies.
Both accepted and rejected findings get a response. Resolve only accepted, fixed threads.

```bash
gh api "repos/{o}/{r}/pulls/<n>/comments/<comment-id>/replies" -f body="Fixed in <sha> — <what>.

agent on behalf of <handle>"
gh pr comment <n> --body="Regarding <source-url>: Not applied — <reason>.

agent on behalf of <handle>"
gh api graphql -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' -f id=<thread-id>
```

Use the same linked PR-comment form for accepted and rejected non-thread findings.

```bash
# TEST: top-level-reply
SOURCE_URL="${SOURCE_URL:?set the finding URL}"
RESPONSE="${RESPONSE:?set the fix or rejection reason}"
RESPOND_GH_HANDLE="${RESPOND_GH_HANDLE:?set the signer handle}"
gh pr comment <n> --body="Regarding $SOURCE_URL: $RESPONSE.

agent on behalf of $RESPOND_GH_HANDLE"
```

Resolve `<handle>` from `RESPOND_GH_HANDLE`, then `gh api user --jq .login`, then `git config user.name`.

## CI and recovery evidence

```bash
gh pr checks <n> --watch --fail-fast
gh pr checks <n> --json name,bucket,link
gh run view <run-id> --log-failed
gh api "repos/{o}/{r}/commits/<queue-head-sha>/check-runs" \
  --jq '.check_runs[] | {name, status, conclusion, details_url}'
gh api "repos/{o}/{r}/issues/<n>/timeline" --paginate \
  -H "Accept: application/vnd.github+json" \
  --jq '.[] | {event, created_at, actor: .actor.login, url}'
```

Use the saved queue head SHA to inspect merge-group checks. Read failed PR and merge-group job logs before repair.
A human removal, policy change, authorization failure, or out-of-scope failure needs the owner.

## Merge and watch

Select an allowed method before the no-merge stop. Set `NO_MERGE=true` for `--no-merge`.
Set `USE_AUTO=true` for protected branches or merge queues. Bind the command to the validated head SHA.

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
  printf 'ready; not merged. Merge command:'
  printf ' %q' "${merge_cmd[@]}"
  printf '\n'
  exit 0
fi
"${merge_cmd[@]}" || {
  printf '%s\n' 'merge command failed' >&2
  exit 1
}
```

The watcher emits one of `ready-for-main-verification`, `recover:<reason>`, or `halt:<reason>`.
Exit 2 means recovery, not success. Set `WATCH_DEADLINE=$(($(date +%s)+1800))` once before the first watch.
Carry that value through recovery; a missing value halts rather than starting another window.
Save `SAVED_QUEUE_ID` with `SAVED_QUEUE_HEAD`. Reuse a head SHA only for the same queue entry.
Clear both only after a verified requeue. An entry without a head SHA stays pending under the original deadline.

```bash
# TEST: merge-watcher
HEAD_SHA="${HEAD_SHA:?set validated head SHA}"
WATCH_DEADLINE="${WATCH_DEADLINE:?set original watch deadline}"
watch_query='query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ pullRequest(number:$n){ state mergedAt mergeCommit{oid} baseRefName headRefOid mergeStateStatus autoMergeRequest{enabledAt} mergeQueueEntry{ id state enqueuedAt headCommit{oid} } } } }'
for ((poll=1; poll<=60; poll++)); do
  if (( $(date +%s) >= WATCH_DEADLINE )); then
    printf '%s\n' 'halt:merge timed out' >&2
    exit 1
  fi
  if ! snapshot="$(gh api graphql -f query="$watch_query" -f o={o} -f r={r} -F n=<n> \
      --jq '.data.repository.pullRequest | [.state, (.mergedAt//"-"), (.mergeCommit.oid//"-"), .baseRefName, .headRefOid, .mergeStateStatus, (if .autoMergeRequest then "enabled" else "disabled" end), (.mergeQueueEntry.id//"-"), (.mergeQueueEntry.headCommit.oid//"-")] | join("|")')"; then
    printf '%s\n' 'halt:API error while polling merge state' >&2
    exit 1
  fi
  IFS='|' read -r state merged_at merge_sha base head merge_status auto queue_id queue_head <<< "$snapshot"
  if [[ -z "$state" || -z "$base" || -z "$head" || -z "$merge_status" || -z "$auto" || -z "$queue_id" || -z "$queue_head" ]]; then
    printf '%s\n' 'halt:malformed PR snapshot' >&2
    exit 1
  fi
  if [[ "$base" != main ]]; then
    printf '%s\n' 'halt:base changed; ask before retargeting' >&2
    exit 1
  fi
  if [[ "$state" == MERGED ]]; then
    if [[ "$merged_at" == - || "$merge_sha" == - ]]; then
      printf '%s\n' 'halt:merge metadata incomplete' >&2
      exit 1
    fi
    printf 'ready-for-main-verification:%s\n' "$merge_sha"
    exit 0
  fi
  if [[ "$state" == CLOSED ]]; then
    printf '%s\n' 'halt:pull request closed without merge' >&2
    exit 1
  fi
  if [[ "$head" != "$HEAD_SHA" ]]; then
    printf '%s\n' 'recover:head changed; revalidate bots and CI' >&2
    exit 2
  fi
  if [[ "$merge_status" == DIRTY ]]; then
    printf '%s\n' 'recover:merge conflicts' >&2
    exit 2
  fi
  if [[ "$queue_id" != - ]]; then
    if [[ "${SAVED_QUEUE_ID:-}" != "$queue_id" ]]; then
      SAVED_QUEUE_ID="$queue_id"
      unset SAVED_QUEUE_HEAD
    fi
    if [[ "$queue_head" != - ]]; then
      SAVED_QUEUE_HEAD="$queue_head"
    elif [[ -n "${SAVED_QUEUE_HEAD:-}" ]]; then
      queue_head="$SAVED_QUEUE_HEAD"
    fi
    if [[ "$queue_head" != - ]]; then
      if ! failed="$(gh api "repos/{o}/{r}/commits/$queue_head/check-runs" --paginate \
          --jq '.check_runs[] | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled") | .id')"; then
        printf '%s\n' 'halt:API error while checking merge group' >&2
        exit 1
      fi
      if [[ -n "$failed" ]]; then
        printf 'recover:merge-group checks failed on %s\n' "$queue_head" >&2
        exit 2
      fi
    fi
  elif [[ -n "${SAVED_QUEUE_ID:-}" ]]; then
    printf 'recover:queue entry disappeared from %s\n' "${SAVED_QUEUE_HEAD:-$SAVED_QUEUE_ID}" >&2
    exit 2
  elif [[ "$auto" == disabled ]]; then
    printf '%s\n' 'recover:auto-merge disabled' >&2
    exit 2
  fi
  if (( poll == 60 )); then
    printf '%s\n' 'halt:merge timed out' >&2
    exit 1
  fi
  sleep 30
done
```

Pending `BLOCKED` with active auto-merge or queue membership waits. An absent queue entry with enabled auto-merge can be pending entry.
Diagnose each `recover` result from timeline and logs. Requeue only after a concrete repair and renewed validation.
Count the recovery once against `--rounds`; never retry the same unchanged failure.

## Verify main inclusion

Do this for an already merged PR too. A PR head SHA is not a safe ancestry witness for squash or rebase.
Use the merge commit as the base and refreshed main as the head. `identical` or `ahead` proves ancestry.

```bash
# TEST: main-ancestry
MERGE_SHA="${MERGE_SHA:?set mergeCommit.oid}"
if ! comparison="$(gh api "repos/{o}/{r}/compare/$MERGE_SHA...main" --jq .status)"; then
  printf '%s\n' 'API error while checking main ancestry' >&2
  exit 1
fi
case "$comparison" in
  identical|ahead) printf '%s\n' 'merged into main' ;;
  *) printf 'merge commit not in main: %s\n' "$comparison" >&2; exit 1 ;;
esac
```
