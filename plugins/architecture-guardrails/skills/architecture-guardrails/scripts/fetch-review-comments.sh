#!/usr/bin/env bash
# Writes the opening comment of every review thread on recently merged PRs as JSON Lines.
# Usage: fetch-review-comments.sh <owner/repo> <max-prs> > comments.jsonl
# One line per thread: {pr, merged_at, author, path, original_line, commit, line, resolved, replies, url, body}.
# original_line is the line in `commit`, the version the reviewer saw; line is its position at the PR head (null when outdated).
# Needs an authenticated gh. Threads are read through GraphQL because REST has no resolved state.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: fetch-review-comments.sh <owner/repo> <max-prs>" >&2
  exit 2
fi
owner=${1%%/*}
repo=${1#*/}
max=$2

# shellcheck disable=SC2016  # $variables in the query are GraphQL variables, not shell
query='
query($owner: String!, $repo: String!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequests(states: MERGED, first: 50, after: $cursor, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number mergedAt
        reviewThreads(first: 50) {
          nodes {
            isResolved path line originalLine
            comments(first: 1) { totalCount nodes { author { login } body url originalCommit { oid } } }
          }
        }
      }
    }
  }
}'

cursor=""
seen=0
while [ "$seen" -lt "$max" ]; do
  args=(-f query="$query" -F owner="$owner" -F repo="$repo")
  [ -n "$cursor" ] && args+=(-F cursor="$cursor")
  page=$(gh api graphql "${args[@]}")
  echo "$page" | jq -c '
    .data.repository.pullRequests.nodes[] | . as $pr
    | .reviewThreads.nodes[] | select(.comments.nodes | length > 0) | .comments.nodes[0] as $c
    | {pr: $pr.number, merged_at: $pr.mergedAt, author: ($c.author.login // "ghost"), path: .path,
       original_line: .originalLine, commit: ($c.originalCommit.oid // null), line: .line, resolved: .isResolved,
       replies: (.comments.totalCount - 1), url: $c.url, body: $c.body}'
  seen=$((seen + $(echo "$page" | jq '.data.repository.pullRequests.nodes | length')))
  [ "$(echo "$page" | jq -r '.data.repository.pullRequests.pageInfo.hasNextPage')" = true ] || break
  cursor=$(echo "$page" | jq -r '.data.repository.pullRequests.pageInfo.endCursor')
done
echo "fetch-review-comments: read $seen merged PRs" >&2
