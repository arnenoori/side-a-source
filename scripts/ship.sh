#!/usr/bin/env bash
# Pushes the version in scripts/Info.plist to every user: signed release, update feed, tag, public
# source, site mirror. Run from an up-to-date main after the version bump and releases/vX.Y.Z.md
# have merged. If a step fails, fix it and run ship.sh again: it skips whatever already happened.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="v$(plutil -extract CFBundleShortVersionString raw scripts/Info.plist)"
build="$(plutil -extract CFBundleVersion raw scripts/Info.plist)"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Check out an up-to-date main first." >&2; exit 1; }
# The site is built and published from the working tree, not from the commit.
if [[ -n "$(git status --porcelain -- site)" ]]; then
  echo "site/ has uncommitted changes, and ship.sh publishes the site from the working tree. Commit or discard them first." >&2
  exit 1
fi
python3 scripts/check-release.py "$tag"
commit="$(git rev-parse HEAD)"
# Everything that could stop the source step is checked now: past this point the binary is public.
remote="${SOURCE_REMOTE:-https://github.com/arnenoori/side-a-source.git}"
git ls-remote -q "$remote" HEAD >/dev/null || { echo "Can't reach $remote." >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/sidea-ship.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/source"
git archive HEAD | tar -x -C "$work/source"
python3 scripts/scan-public-source.py "$work/source"

# Signs, notarizes and publishes the binary and then the feed, on the Mac's one-job runner.
release() {
  # The release runner is one-job (ephemeral), so each release registers it again; a missing runner
  # otherwise leaves the job queued with no error.
  online() { gh api "repos/{owner}/{repo}/actions/runners" -q '[.runners[] | select(.status == "online" and any(.labels[]; .name == "side-a-release"))] | length'; }
  if [[ "$(online)" == 0 ]]; then
    # Outside ~/scratch, which is cleared out from time to time. No spaces: the runner's scripts don't quote paths.
    runner="${SIDEA_RUNNER_DIR:-$HOME/.local/share/side-a/release-runner}"
    if [[ ! -x "$runner/run.sh" ]]; then
      # GitHub's own runner, checked against the SHA-256 its release notes publish for this Mac's architecture.
      arch=$([[ "$(uname -m)" == arm64 ]] && echo osx-arm64 || echo osx-x64)
      latest=$(gh api repos/actions/runner/releases/latest)
      version=$(jq -r .tag_name <<<"$latest")
      sum=$(jq -r .body <<<"$latest" | sed -n "s/.*<!-- BEGIN SHA $arch -->\([0-9a-f]\{64\}\)<!-- END SHA $arch -->.*/\1/p")
      [[ -n "$sum" ]] || { echo "GitHub's runner $version lists no SHA-256 for $arch; install it at $runner yourself (see docs/updates.md)." >&2; exit 1; }
      archive="$work/runner.tar.gz"
      curl -fsSL -o "$archive" "https://github.com/actions/runner/releases/download/$version/actions-runner-$arch-${version#v}.tar.gz"
      echo "$sum  $archive" | shasum -a 256 -c --quiet || { echo "The runner download doesn't match GitHub's SHA-256." >&2; exit 1; }
      mkdir -p "$runner" && tar xzf "$archive" -C "$runner"
      echo "Installed GitHub's runner $version at $runner."
    fi
    if [[ ! -f "$runner/.runner" ]]; then
      token=$(gh api -X POST "repos/{owner}/{repo}/actions/runners/registration-token" -q .token)
      repository=$(gh repo view --json nameWithOwner -q .nameWithOwner)
      (cd "$runner" && ./config.sh --unattended --url "https://github.com/$repository" --token "$token" \
        --ephemeral --no-default-labels --labels side-a-release --name "side-a-release-$(date +%Y%m%d-%H%M%S)" --replace >/dev/null)
    fi
    (cd "$runner" && nohup ./run.sh > run.log 2>&1 &)
    for _ in $(seq 30); do [[ "$(online)" != 0 ]] && break; sleep 2; done
    [[ "$(online)" != 0 ]] || { echo "The release runner didn't come online; see $runner/run.log." >&2; exit 1; }
  fi
  runs() { gh run list --workflow local-release.yml --event workflow_dispatch --limit 20 --json databaseId,headSha -q '.[] | "\(.databaseId) \(.headSha)"'; }
  # An earlier ship.sh that was interrupted may have left a run for this commit going: watch it, don't sign twice.
  run="$(gh run list --workflow local-release.yml --event workflow_dispatch --limit 20 --json databaseId,headSha,status \
    -q '[.[] | select(.status != "completed" and .headSha == "'"$commit"'")][0].databaseId // empty')"
  before="$(runs)"
  if [[ -n "$run" ]]; then echo "Release run $run for $commit is already going; watching it."
  else gh workflow run local-release.yml --ref main -f tag="$tag"; fi
  # Otherwise the run this dispatch made is the new one; it has to build the commit checked above.
  for _ in $(seq 60); do
    [[ -n "$run" ]] && break
    sleep 3
    while read -r id sha; do
      [[ -z "$id" ]] || grep -q "^$id " <<<"$before" && continue
      if [[ "$sha" != "$commit" ]]; then
        gh run cancel "$id" >/dev/null && did="Cancelled it" || did="Cancelling it failed: gh run cancel $id"
        echo "Release run $id builds $sha, not $commit: main moved after ship.sh checked it. $did; then run ship.sh again." >&2
        exit 1
      fi
      run="$id"
    done <<<"$(runs)"
    [[ -n "$run" ]] && break
  done
  [[ -n "$run" ]] || { echo "No release run for $commit appeared within 3 minutes; see gh run list --workflow local-release.yml." >&2; exit 1; }
  gh run watch "$run" --exit-status
  ran="$(gh run view "$run" --json headSha -q .headSha)"
  [[ "$ran" == "$commit" ]] || { echo "Release run $run built $ran, not $commit. Stopping before the tag, source and site." >&2; exit 1; }
}

# A rerun after a later step failed: the binary and its feed are already out, so don't sign again.
dispatched=0
case "$(python3 scripts/publish-appcast.py --state)" in
  published) echo "$tag is already published with build $build in the update feed; continuing after it." ;;
  release-only)
    echo "$tag is published, but the update feed doesn't carry build $build. Publish the feed from that release's dist/ with scripts/publish-appcast.py, then run ship.sh again." >&2
    exit 1 ;;
  unpublished) release; dispatched=1 ;;
  *) echo "Can't tell whether $tag is published." >&2; exit 1 ;;
esac

# The tag names the commit that was built. On a rerun with no tag yet, that's the commit of the
# successful release run whose Info.plist has this version and build.
if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  if git ls-remote -q --exit-code origin "refs/tags/$tag" >/dev/null; then
    git fetch -q origin "refs/tags/$tag:refs/tags/$tag"
  elif [[ "$dispatched" == 1 ]]; then
    git tag "$tag" "$commit"
  else
    built=$(gh run list --workflow local-release.yml --status success --limit 50 --json headSha -q '.[].headSha' | sort -u | while read -r sha; do
      plist="$(git show "$sha:scripts/Info.plist" 2>/dev/null)" || continue
      if [[ "$(plutil -extract CFBundleShortVersionString raw - <<<"$plist")" == "${tag#v}" \
            && "$(plutil -extract CFBundleVersion raw - <<<"$plist")" == "$build" ]]; then echo "$sha"; fi
    done)
    [[ -n "$built" && "$(wc -l <<<"$built")" -eq 1 ]] || {
      echo "$tag is published but has no git tag, and no single successful release run names its commit. Tag it with git tag $tag <commit> and run ship.sh again." >&2
      exit 1
    }
    git tag "$tag" "$built"
  fi
fi
if [[ "$dispatched" == 1 && "$(git rev-parse "$tag^{commit}")" != "$commit" ]]; then
  echo "The local tag $tag points at $(git rev-parse "$tag^{commit}"), not the commit just released ($commit). Stopping." >&2
  exit 1
fi
pushed="$(git ls-remote -q origin "refs/tags/$tag" | cut -f1)"
if [[ -z "$pushed" ]]; then git push -q origin "refs/tags/$tag"
elif [[ "$pushed" != "$(git rev-parse "refs/tags/$tag")" ]]; then
  echo "origin's tag $tag differs from the local one. Stopping." >&2
  exit 1
fi
# publish-source.sh also says so and stops when the mirror has the tag; this skips its clone.
if git ls-remote -q --exit-code "$remote" "refs/tags/$tag" >/dev/null; then echo "Source for $tag is already public."
else ./scripts/publish-source.sh "$tag"; fi
# Least important, so last: publish-site.py does nothing when the mirror is current.
npm --prefix site ci && npm --prefix site run build && python3 scripts/publish-site.py
echo "Shipped $tag. Running copies of Side A show \"Update to ${tag#v}\" in the menu."
