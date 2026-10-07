#!/bin/bash
# Publishes a release tag's source to the public repository as one commit, without history.
# Files marked export-ignore in .gitattributes stay private.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:?Release tag required}"
remote="${SOURCE_REMOTE:-git@github.com:arnenoori/side-a-source.git}"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sidea-source.XXXXXX")"
trap 'rm -rf "$work"' EXIT
git clone -q "$remote" "$work/mirror"
git -C "$work/mirror" rm -rq --ignore-unmatch -- .
git archive "$tag" | tar -x -C "$work/mirror"
git -C "$work/mirror" add -A
if git -C "$work/mirror" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Source for $tag is already public." && exit 0
fi
git -C "$work/mirror" -c user.name="Arne Noori" -c user.email="19876710+arnenoori@users.noreply.github.com" \
  commit -q --allow-empty -m "Side A ${tag#v}"
git -C "$work/mirror" tag "$tag"
git -C "$work/mirror" push -q origin HEAD:main "$tag"
echo "Published source for $tag."
