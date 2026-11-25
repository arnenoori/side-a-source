#!/usr/bin/env bash
# Builds the Linux packages for sidead, in Docker, so the result does not depend on this machine:
#   side-a-daemon-<version>-linux-<arch>.tar.gz   the binary, the Python bridge, install.sh and a systemd user unit
#   side-a-daemon_<version>_<arch>.deb            the same for apt (needs tmux >= 3.4 and python3)
#   scripts/package-sidead.sh                     this machine's architecture
#   scripts/package-sidead.sh --arch amd64        or arm64; "both" builds the two (the foreign one under emulation, slow)
#   scripts/package-sidead.sh --out DIR           where the files go (default dist/linux)
# The binary is built on Ubuntu 24.04 (glibc 2.39; SideACore uses memmem, which the 22.04 image does not expose) with the Swift runtime linked in, so it runs on Ubuntu 24.04 and newer,
# Debian 13 and newer, and anything with a glibc that new. SIDEA_PACKAGE_IMAGE picks another build image.
set -euo pipefail
cd "$(dirname "$0")/.."

case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
out=dist/linux
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch="${2:?--arch needs arm64, amd64 or both}"; shift 2 ;;
    --out) out="${2:?--out needs a folder}"; shift 2 ;;
    *) echo "usage: scripts/package-sidead.sh [--arch arm64|amd64|both] [--out DIR]" >&2; exit 2 ;;
  esac
done
command -v docker >/dev/null || { echo "package-sidead.sh: docker is not installed or not running." >&2; exit 1; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Daemon/Sources/SideADaemonKit/SideADaemon.swift | head -1)"
[[ -n "$version" ]] || { echo "package-sidead.sh: couldn't read the daemon's version." >&2; exit 1; }
image="${SIDEA_PACKAGE_IMAGE:-swift:6.2-noble}"

build() {
  local arch="$1" volume="sidea-package-work-$1"
  docker volume create "$volume" >/dev/null
  printf '\n== sidead %s for linux/%s (%s)\n' "$version" "$arch" "$image"
  docker run --rm --platform "linux/$arch" -e "VERSION=$version" -e "ARCH=$arch" -v "$PWD":/src:ro -v "$volume":/work -v "$out":/out "$image" bash -c '
    set -euo pipefail
    cd /work
    find . -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
    tar -C /src --exclude=.build --exclude=./.git --exclude=./site --exclude=./relay --exclude=./apps --exclude=./dist --exclude=./design --exclude=node_modules -cf - . | tar -C /work -xf -
    log=/work/build.log
    swift build --package-path Daemon --scratch-path /work/.build/daemon -c release --product sidead --static-swift-stdlib > "$log" 2>&1 || {
      grep -v "^\[" "$log" | grep -i -B3 -A12 "error:\|stack dump\|While " | head -60; exit 1; }
    tail -2 "$log"
    bin=/work/.build/daemon/release/sidead
    "$bin" --version
    strip "$bin" || true

    name="side-a-daemon-$VERSION-linux-$ARCH"
    stage="/tmp/$name"
    rm -rf "$stage" && mkdir -p "$stage/bin" "$stage/share/side-a" "$stage/lib/systemd/user"
    install -m 755 "$bin" "$stage/bin/sidead"
    mkdir "$stage/share/side-a/bridge"
    cp bridge/*.py "$stage/share/side-a/bridge/"
    install -m 644 Daemon/Packaging/sidead.service "$stage/lib/systemd/user/sidead.service"
    install -m 755 Daemon/Packaging/install.sh Daemon/Packaging/uninstall.sh "$stage/"
    install -m 644 LICENSE "$stage/LICENSE"
    tar -C /tmp --owner=0 --group=0 -czf "/out/$name.tar.gz" "$name"

    deb="/tmp/deb"
    rm -rf "$deb" && mkdir -p "$deb/DEBIAN" "$deb/usr/bin" "$deb/usr/share/side-a" "$deb/usr/lib/systemd/user"
    install -m 755 "$bin" "$deb/usr/bin/sidead"
    cp -R "$stage/share/side-a/bridge" "$deb/usr/share/side-a/bridge"
    sed "s|@BIN@|/usr/bin/sidead|" Daemon/Packaging/sidead.service > "$deb/usr/lib/systemd/user/sidead.service"
    chmod 644 "$deb/usr/lib/systemd/user/sidead.service"
    find "$deb/usr/share" -type f -exec chmod 644 {} +
    cat > "$deb/DEBIAN/control" <<CONTROL
Package: side-a-daemon
Version: $VERSION
Architecture: $ARCH
Maintainer: Side A <noreply@invalid>
Section: utils
Priority: optional
Depends: libcurl4t64 | libcurl4, tmux (>= 3.4), python3 (>= 3.9)
Description: Side A Remote for this computer
 sidead lets the Side A Remote iPhone app list, read and answer Claude Code and
 Codex sessions on this computer, and start new ones in tmux. Pair it with
 "sidead pair"; enable it with "systemctl --user enable --now sidead".
CONTROL
    dpkg-deb --root-owner-group --build "$deb" "/out/side-a-daemon_${VERSION}_$ARCH.deb" >/dev/null
    chown -R "$(stat -c %u:%g /out)" /out/*.tar.gz /out/*.deb 2>/dev/null || true'
}

case "$arch" in
  both) build arm64; build amd64 ;;
  arm64 | amd64) build "$arch" ;;
  *) echo "package-sidead.sh: --arch must be arm64, amd64 or both." >&2; exit 2 ;;
esac
printf '\n'
ls -l "$out"/side-a-daemon*
