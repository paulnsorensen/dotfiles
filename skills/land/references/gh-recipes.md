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

Wait for completion: poll the reviews endpoint every 30 seconds for a bot review with `submitted_at` newer than the request, or a bot issue comment newer than the request that is not another rate-limit message.

```bash
until gh api "repos/{o}/{r}/pulls/<n>/reviews" --paginate \
    --jq --arg t "$REQUESTED_AT" '[.[] | select(.user.login=="coderabbitai[bot]" and .submitted_at > $t)] | length' \
    | grep -qv '^0$'; do sleep 30; done
```

Bound the loop with a counter (40 iterations = 20 minutes).

## Open review threads (GraphQL)

```bash
gh api graphql -f query='
query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){ pullRequest(number:$n){
    reviewThreads(first:100){ nodes{
      id isResolved isOutdated path line
      comments(first:10){ nodes{ id databaseId author{login} body } }
    } }
  } }
}' -f o={o} -f r={r} -F n=<n> \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
        | select(.isResolved==false and .comments.nodes[0].author.login=="coderabbitai")'
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

```bash
gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed,deleteBranchOnMerge
gh pr merge <n> --squash --delete-branch            # direct
gh pr merge <n> --squash --delete-branch --auto     # protected branch or merge queue

for i in $(seq 1 60); do
  s=$(gh pr view <n> --json state,mergedAt --jq '"\(.state) \(.mergedAt // "")"')
  case "$s" in MERGED*) printf '%s\n' "$s"; break ;; esac
  sleep 30
done
```

`mergeStateStatus` values: `CLEAN` merge now; `BLOCKED` a required check or review is missing; `DIRTY` conflicts, route to `/melt`; `UNSTABLE` a non-required check failed.
