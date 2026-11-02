#!/usr/bin/env bash
# Pushes the version in scripts/Info.plist to every user: signed release, update feed, site mirror.
# Run from an up-to-date main after the version bump and releases/vX.Y.Z.md have merged.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="v$(plutil -extract CFBundleShortVersionString raw scripts/Info.plist)"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Check out an up-to-date main first." >&2; exit 1; }
python3 scripts/check-release.py "$tag"
commit="$(git rev-parse HEAD)"
# Everything that could stop the source step is checked now: past this point the binary is public.
remote="${SOURCE_REMOTE:-https://github.com/arnenoori/side-a-source.git}"
git ls-remote -q "$remote" HEAD >/dev/null || { echo "Can't reach $remote." >&2; exit 1; }
preflight="$(mktemp -d "${TMPDIR:-/tmp}/sidea-preflight.XXXXXX")"
trap 'rm -rf "$preflight"' EXIT
git archive HEAD | tar -x -C "$preflight"
python3 scripts/scan-public-source.py "$preflight"
# The release runner is one-job (ephemeral), so each release registers it again; a missing runner
# otherwise leaves the job queued with no error.
online() { gh api "repos/{owner}/{repo}/actions/runners" -q '[.runners[] | select(.status == "online" and any(.labels[]; .name == "side-a-release"))] | length'; }
if [[ "$(online)" == 0 ]]; then
  # Outside ~/scratch, which is cleared out from time to time. No spaces: the runner's scripts don't quote paths.
  runner="${SIDEA_RUNNER_DIR:-$HOME/.local/share/side-a/release-runner}"
  if [[ ! -x "$runner/run.sh" ]]; then
    # GitHub's own runner, checked against the SHA-256 its release notes publish for this Mac's architecture.
    arch=$([[ "$(uname -m)" == arm64 ]] && echo osx-arm64 || echo osx-x64)
    release=$(gh api repos/actions/runner/releases/latest)
    version=$(jq -r .tag_name <<<"$release")
    sum=$(jq -r .body <<<"$release" | sed -n "s/.*<!-- BEGIN SHA $arch -->\([0-9a-f]\{64\}\)<!-- END SHA $arch -->.*/\1/p")
    [[ -n "$sum" ]] || { echo "GitHub's runner $version lists no SHA-256 for $arch; install it at $runner yourself (see docs/updates.md)." >&2; exit 1; }
    archive=$(mktemp -t side-a-runner).tar.gz
    curl -fsSL -o "$archive" "https://github.com/actions/runner/releases/download/$version/actions-runner-$arch-${version#v}.tar.gz"
    echo "$sum  $archive" | shasum -a 256 -c --quiet || { rm -f "$archive"; echo "The runner download doesn't match GitHub's SHA-256." >&2; exit 1; }
    mkdir -p "$runner" && tar xzf "$archive" -C "$runner" && rm -f "$archive"
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
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run local-release.yml --ref main -f tag="$tag"
run=""
until [[ -n "$run" ]]; do
  sleep 3
  run=$(gh run list --workflow local-release.yml --limit 1 --json databaseId,createdAt -q ".[] | select(.createdAt >= \"$started\") | .databaseId")
done
gh run watch "$run" --exit-status
npm --prefix site ci && npm --prefix site run build && python3 scripts/publish-site.py
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag "$tag" "$commit"
git push -q origin "refs/tags/$tag"
./scripts/publish-source.sh "$tag"
echo "Shipped $tag. Running copies of Side A show \"Update to ${tag#v}\" in the menu."
