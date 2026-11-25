#!/usr/bin/env bash
# Builds, checks and (only with --publish) releases sidead, the Linux daemon, as release sidead-v<version> of the
# public releases repository, the one the Mac dmg goes to. The Mac's own release (ship.sh, v<version>) is not touched:
# its "latest" stays the latest, the update feed is not involved, and the site finds this release by its tag.
#
#   scripts/ship-sidead.sh                 build both architectures, check each package, write SHA256SUMS.txt in dist/linux
#   scripts/ship-sidead.sh --publish       then release them (the only step that touches GitHub; needs the owner's yes)
#   --out DIR         where the packages and sums go (default dist/linux)
#   --skip-build      use the packages already in --out (named for the version in the source)
#   --skip-verify     do not install each package in a clean container and pair with it
#
# The version is `SideADaemon.version` and must be MAJOR.MINOR.PATCH; releases/sidead-v<version>.md is the public notes.
set -euo pipefail
cd "$(dirname "$0")/.."

out=dist/linux publish=no build=yes verify=yes
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="${2:?--out needs a folder}"; shift 2 ;;
    --publish) publish=yes; shift ;;
    --skip-build) build=no; shift ;;
    --skip-verify) verify=no; shift ;;
    *) echo "usage: scripts/ship-sidead.sh [--out DIR] [--skip-build] [--skip-verify] [--publish]" >&2; exit 2 ;;
  esac
done

repository="${SIDEAD_RELEASES_REPOSITORY:-arnenoori/side-a-releases}"
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Daemon/Sources/SideADaemonKit/SideADaemon.swift | head -1)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ship-sidead.sh: the daemon's version is '$version'; a release needs MAJOR.MINOR.PATCH." >&2; exit 1; }
tag="sidead-v$version"
notes="releases/$tag.md"
[[ -s "$notes" ]] || { echo "ship-sidead.sh: $notes (the public release notes) is missing." >&2; exit 1; }
grep -q "^## $version\b\|^## Unreleased" CHANGELOG.md || { echo "ship-sidead.sh: CHANGELOG.md has no entry for $version." >&2; exit 1; }

mkdir -p "$out"
out="$(cd "$out" && pwd)"
files=("side-a-daemon-$version-linux-amd64.tar.gz" "side-a-daemon-$version-linux-arm64.tar.gz"
       "side-a-daemon_${version}_amd64.deb" "side-a-daemon_${version}_arm64.deb")

sum() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
step() { printf '\n== %s\n' "$*"; }

if [[ "$build" == yes ]]; then
  step "building $version for amd64 and arm64"
  rm -f "$out"/side-a-daemon*
  scripts/package-sidead.sh --arch both --out "$out"
fi
for file in "${files[@]}"; do
  [[ -s "$out/$file" ]] || { echo "ship-sidead.sh: $out/$file is missing." >&2; exit 1; }
done

if [[ "$verify" == yes ]]; then
  for arch in amd64 arm64; do
    step "the $arch tarball: install.sh in a clean ubuntu:24.04, pair, list, host, reply, transcript"
    scripts/linux-e2e.sh "--$arch" --package "$out/side-a-daemon-$version-linux-$arch.tar.gz"
    step "the $arch .deb: apt install in a clean ubuntu:24.04"
    docker run --rm --platform "linux/$arch" -v "$out/side-a-daemon_${version}_$arch.deb":/pkg.deb:ro ubuntu:24.04 bash -c '
      set -euo pipefail
      apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /pkg.deb >/dev/null
      [[ "$(sidead --version)" == "sidead '"$version"'" ]]
      dpkg -s side-a-daemon | grep -q "^Version: '"$version"'"
      test -f /usr/lib/systemd/user/sidead.service && test -f /usr/share/side-a/bridge/hostos.py
      echo "installed: $(sidead --version), tmux $(tmux -V), $(python3 --version)"'
  done
fi

step "SHA256SUMS.txt"
(cd "$out" && sum "${files[@]}" > SHA256SUMS.txt && sum -c SHA256SUMS.txt)
cat "$out/SHA256SUMS.txt"

if [[ "$publish" != yes ]]; then
  printf '\nReady: %s for %s. Release it with: scripts/ship-sidead.sh --publish --skip-build --skip-verify (after the owner says yes).\n' "$tag" "$out"
  exit 0
fi

# Everything below talks to GitHub. Past the release being public, the one-liner on the site starts installing it.
step "publishing $tag to $repository"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "ship-sidead.sh: check out an up-to-date main first." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "ship-sidead.sh: the working tree has uncommitted changes." >&2; exit 1; }
list="$(gh release list --repo "$repository" --limit 1000 --json tagName,isDraft)"
state="$(printf '%s' "$list" | python3 -c 'import json,sys; r=next((r for r in json.load(sys.stdin) if r["tagName"] == sys.argv[1]), None); print("missing" if r is None else "draft" if r["isDraft"] else "published")' "$tag")"
case "$state" in
  published) echo "ship-sidead.sh: $tag is already published; make a new version." >&2; exit 1 ;;
  missing) gh release create "$tag" --repo "$repository" --draft --latest=false --title "sidead $version" --notes-file "$notes" ;;
  draft) ;;
esac
paths=()
for file in "${files[@]}" SHA256SUMS.txt; do paths+=("$out/$file"); done
gh release upload "$tag" "${paths[@]}" --repo "$repository" --clobber
# --latest=false: the Mac app's release stays the repository's latest, which the site and Sparkle read.
gh release edit "$tag" --repo "$repository" --draft=false --latest=false --notes-file "$notes"
if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then git tag "$tag" HEAD; fi
[[ -n "$(git ls-remote -q origin "refs/tags/$tag")" ]] || git push -q origin "refs/tags/$tag"
printf '\nPublished %s. Check: curl -fsSL https://getsidea.com/install.sh | sh\n' "$tag"
