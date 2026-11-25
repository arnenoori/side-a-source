#!/usr/bin/env bash
# Squash-merges a pull request, but only when its head commit has passed scripts/check.sh on this Mac.
# Use it instead of `gh pr merge`:  scripts/merge-pr.sh <number>
#
# The proof is a successful `local-check` commit status on the PR's head sha (posted by check.sh, by the pre-push
# hook, or by this script). With no such status the script runs check.sh on that exact commit in a clean temporary
# worktree, which posts the status when it passes, and merges only if it did. Merging never happens on a failure.
set -euo pipefail
cd "$(dirname "$0")/.."
number="${1:-}"
if [[ ! "$number" =~ ^[0-9]+$ ]]; then echo "usage: scripts/merge-pr.sh <pull request number>" >&2; exit 2; fi

# GitHub's API lags right after a push or a status post, so the PR head and the status are read a few times, with a
# short bounded wait, before "no status" is believed. SIDEA_MERGE_ATTEMPTS and SIDEA_MERGE_INTERVAL tune the wait.
attempts="${SIDEA_MERGE_ATTEMPTS:-4}"
interval="${SIDEA_MERGE_INTERVAL:-3}"

read_pr() { read -r state draft head < <(gh pr view "$number" --json state,isDraft,headRefOid --jq '[.state, .isDraft, .headRefOid] | @tsv'); }
read_pr
sha="$head"
if [[ "$state" != OPEN ]]; then echo "merge-pr.sh: #$number is $state, not open." >&2; exit 1; fi
if [[ "$draft" == true ]]; then echo "merge-pr.sh: #$number is a draft." >&2; exit 1; fi

# Refuses when the PR's head is no longer the commit read first.
require_same_head() {
  read_pr
  if [[ "$head" != "$sha" ]]; then
    echo "merge-pr.sh: the head of #$number changed from $sha to $head while this ran (a new push, or GitHub was still catching up). Nothing was merged; run it again." >&2
    exit 1
  fi
}

# Whether local-check is currently success on the sha. The combined status keeps only the newest state per context.
local_check_passed() {
  [[ "$(gh api "repos/{owner}/{repo}/commits/$sha/status" --jq '[.statuses[] | select(.context == "local-check") | .state] | first // ""')" == success ]]
}

# local_check_passed, retried a bounded number of times while the PR head stays the same.
local_check_settled() {
  local try=1
  while :; do
    if local_check_passed; then return 0; fi
    if [[ "$try" -ge "$attempts" ]]; then return 1; fi
    try=$((try + 1))
    sleep "$interval"
    require_same_head
  done
}

if local_check_settled; then
  echo "merge-pr.sh: $sha already has a successful local-check status."
else
  echo "merge-pr.sh: $sha has no successful local-check status, so checking it here first."
  git fetch -q origin main "pull/$number/head"
  ./scripts/check.sh --sha "$sha"
  require_same_head
  if ! local_check_settled; then
    echo "merge-pr.sh: the checks passed but no local-check success is on $sha (is gh signed in?). Not merging." >&2
    exit 1
  fi
fi

gh pr merge "$number" --squash --match-head-commit "$sha"
