#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:?Release tag required}"
python3 scripts/check-release.py "$tag"
repository="arnenoori/side-a-releases"
version="${tag#v}"
archive="dist/SideA-$version-macOS-universal.zip"
dmg="dist/SideA-$version-macOS-universal.dmg"
test -f "$archive"
test -f "$dmg"
python3 scripts/verify-downloads.py
# Published versions are immutable. A failed draft can be retried safely.
release_list="$(gh release list --repo "$repository" --limit 1000 --json tagName,isDraft)"
state="$(printf '%s' "$release_list" | python3 -c 'import json,sys; r=next((r for r in json.load(sys.stdin) if r["tagName"] == sys.argv[1]), None); print("missing" if r is None else "draft" if r["isDraft"] else "published")' "$tag")"
case "$state" in
  published) echo "Version already published; create a new version" >&2; exit 1 ;;
  missing) gh release create "$tag" --repo "$repository" --draft --title "Side A $version" --notes-file "releases/$tag.md" ;;
  draft) ;;
esac
gh release upload "$tag" "$dmg" "$archive" dist/SHA256SUMS.txt --repo "$repository" --clobber
gh release edit "$tag" --repo "$repository" --draft=false --latest --notes-file "releases/$tag.md"
