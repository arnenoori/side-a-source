#!/usr/bin/env bash
# Pushes the version in scripts/Info.plist to every user: signed release, update feed, site mirror.
# Run from an up-to-date main after the version bump and releases/vX.Y.Z.md have merged.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="v$(plutil -extract CFBundleShortVersionString raw scripts/Info.plist)"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "Check out an up-to-date main first." >&2; exit 1; }
python3 scripts/check-release.py "$tag"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run local-release.yml --ref main -f tag="$tag"
run=""
until [[ -n "$run" ]]; do
  sleep 3
  run=$(gh run list --workflow local-release.yml --limit 1 --json databaseId,createdAt -q ".[] | select(.createdAt >= \"$started\") | .databaseId")
done
gh run watch "$run" --exit-status
npm --prefix site ci && npm --prefix site run build && python3 scripts/publish-site.py
echo "Shipped $tag. Running copies of Side A show \"Update to ${tag#v}\" in the menu."
