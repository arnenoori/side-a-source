#!/bin/sh
# Installs sidead, the Side A daemon for Linux (and Windows through WSL 2), for the current user:
#   curl -fsSL https://getsidea.com/install.sh | sh
#   curl -fsSL https://getsidea.com/install.sh | sh -s -- --no-service     (what follows -- goes to the package's install.sh)
# It picks the package for this computer's architecture, checks it against the release's SHA-256 sums, and runs the
# package's own install.sh (files under ~/.local, a systemd user service). Nothing is installed with root.
#   SIDEAD_VERSION=0.1.0   a version other than the latest
#   SIDEAD_BASE_URL=URL    where the files are (a folder holding the tarballs and SHA256SUMS.txt); for mirrors and tests
set -eu

repository="${SIDEAD_REPOSITORY:-arnenoori/side-a-releases}"
need_glibc_major=2
need_glibc_minor=39

fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail "this installs the Linux daemon. On a Mac, use the app from https://getsidea.com; on Windows, run it inside WSL 2 (Ubuntu 24.04)."

case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) fail "$(uname -m) isn't supported. sidead is built for x86-64 and arm64." ;;
esac

distro=Linux
if [ -r /etc/os-release ]; then
  # A subshell, so os-release's variables don't land in this script.
  # shellcheck source=/dev/null
  distro="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-Linux}")"
fi

libc="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
case "$libc" in
  glibc\ *) ;;
  *) fail "this system doesn't use glibc ($distro), which sidead needs. Use Ubuntu 24.04 or newer, or Debian 13 or newer." ;;
esac
libc="${libc#glibc }"
major="${libc%%.*}"
rest="${libc#*.}"
minor="${rest%%.*}"
case "$major$minor" in *[!0-9]* | "") fail "couldn't read this system's glibc version ($libc)." ;; esac
if [ "$major" -lt "$need_glibc_major" ] || { [ "$major" -eq "$need_glibc_major" ] && [ "$minor" -lt "$need_glibc_minor" ]; }; then
  fail "$distro has glibc $libc, and sidead needs $need_glibc_major.$need_glibc_minor or newer (Ubuntu 24.04, Debian 13, Fedora 40)."
fi

if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }
  fetch_text() { curl -fsSL --retry 3 "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -q -O "$2" "$1"; }
  fetch_text() { wget -q -O - "$1"; }
else
  fail "curl or wget is needed to download sidead (sudo apt install curl)."
fi
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  fail "sha256sum is needed to check the download (it is part of coreutils)."
fi
command -v tar >/dev/null 2>&1 || fail "tar is needed to unpack sidead."

version="${SIDEAD_VERSION:-}"
if [ -z "$version" ]; then
  [ -z "${SIDEAD_BASE_URL:-}" ] || fail "with SIDEAD_BASE_URL, also set SIDEAD_VERSION."
  listing="$(fetch_text "https://api.github.com/repos/$repository/releases?per_page=30")" || fail "couldn't ask GitHub for the latest sidead release."
  version="$(printf '%s\n' "$listing" | sed -n 's/.*"tag_name": *"sidead-v\([0-9][0-9.]*\)".*/\1/p' | head -n 1)"
  [ -n "$version" ] || fail "no sidead release has been published yet."
fi
case "$version" in *[!0-9.]* | "") fail "$version isn't a version number." ;; esac

base="${SIDEAD_BASE_URL:-https://github.com/$repository/releases/download/sidead-v$version}"
base="${base%/}"
name="side-a-daemon-$version-linux-$arch.tar.gz"

work="$(mktemp -d "${TMPDIR:-/tmp}/sidead-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

printf 'Downloading sidead %s for %s (%s)\n' "$version" "$arch" "$distro"
fetch "$base/SHA256SUMS.txt" "$work/SHA256SUMS.txt" || fail "couldn't download $base/SHA256SUMS.txt."
fetch "$base/$name" "$work/$name" || fail "couldn't download $base/$name."

want="$(sed -n "s/^\\([0-9a-f]\\{64\\}\\)  *\\**$name\$/\\1/p" "$work/SHA256SUMS.txt" | head -n 1)"
[ -n "$want" ] || fail "SHA256SUMS.txt doesn't list $name."
have="$(sha256 "$work/$name")"
[ "$have" = "$want" ] || fail "$name doesn't match its SHA-256 (expected $want, got $have). Nothing was installed."
printf 'Checksum ok.\n'

tar -xzf "$work/$name" -C "$work"
folder="$work/side-a-daemon-$version-linux-$arch"
[ -x "$folder/install.sh" ] || fail "the package has no install.sh."
if [ "$(id -u)" = 0 ]; then
  printf 'Note: installing for root. Run this as your own user for the phone to see your sessions.\n' >&2
fi
cd "$folder"
./install.sh "$@"
