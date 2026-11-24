#!/usr/bin/env bash
# Builds and tests what is portable to Linux: the protocol package (with its fixture suite), SideACore and its tests,
# and the sidead daemon spike. Run in Docker from a Mac, or with --here on a Linux machine (what CI does).
#   scripts/linux-check.sh                 swift:6.2-noble in Docker, this machine's architecture
#   scripts/linux-check.sh --amd64         the same under linux/amd64 emulation (slow)
#   scripts/linux-check.sh --here          this machine, which must be Linux with Swift 6 installed
# SIDEA_SWIFT_IMAGE picks another image. The container works on a copy of the tree held in the Docker volume
# sidea-linux-work-<arch>, so nothing is written into the checkout and Package.resolved is never touched; the volume also keeps
# the build between runs. Remove them with: docker volume rm sidea-linux-work-arm64 sidea-linux-work-amd64
set -euo pipefail
cd "$(dirname "$0")/.."

mode=docker
case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
case "${1:-}" in
  --here) mode=here ;;
  --amd64) arch=amd64 ;;
  "") ;;
  *) echo "usage: scripts/linux-check.sh [--here | --amd64]" >&2; exit 2 ;;
esac

if [[ "$mode" == docker ]]; then
  command -v docker >/dev/null || { echo "linux-check.sh: docker is not installed or not running." >&2; exit 1; }
  image="${SIDEA_SWIFT_IMAGE:-swift:6.2-noble}"
  volume="sidea-linux-work-$arch"
  docker volume create "$volume" >/dev/null
  exec docker run --rm --platform "linux/$arch" -v "$PWD":/src:ro -v "$volume":/work "$image" bash -c '
    set -euo pipefail
    cd /work
    find . -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
    tar -C /src --exclude=.build --exclude=./.git --exclude=./site --exclude=./relay --exclude=./apps --exclude=node_modules -cf - . | tar -C /work -xf -
    SIDEA_LINUX_SCRATCH=/work/.build exec scripts/linux-check.sh --here'
fi

[[ "$(uname -s)" == Linux ]] || { echo "linux-check.sh: --here needs Linux; run without it to use Docker." >&2; exit 1; }
swift --version
step() { printf '\n== %s\n' "$*"; }
# In Docker the build products live in the volume, one directory per package, so they survive the tree being copied again.
# `sw NAME PACKAGE_DIR ARGS...` runs swift in that package with its own scratch directory.
sw() {
  local name="$1" dir="$2"; shift 2
  if [[ -n "${SIDEA_LINUX_SCRATCH:-}" ]]; then swift "$1" --package-path "$dir" --scratch-path "$SIDEA_LINUX_SCRATCH/$name" "${@:2}"
  else swift "$1" --package-path "$dir" "${@:2}"; fi
}

step "SideAProtocol: build and test (fixture conformance included)"
sw protocol Packages/SideAProtocol build --build-tests
sw protocol Packages/SideAProtocol test --skip-build

step "SideACore: build and test"
sw core . build --build-tests
sw core . test --skip-build

step "sidead: build, test (TLS 1.3 hello over a pinned key), and start the binary"
sw daemon Daemon build --build-tests
sw daemon Daemon test --skip-build
daemon_bin="$(sw daemon Daemon build --show-bin-path)/sidead"
daemon_log="$(mktemp)"
"$daemon_bin" --port 47831 >"$daemon_log" &
daemon=$!
trap 'kill "$daemon" 2>/dev/null || true; rm -f "$daemon_log"' EXIT
for _ in $(seq 1 50); do grep -q listening "$daemon_log" && break; sleep 0.1; done
grep -q listening "$daemon_log" || { cat "$daemon_log" >&2; echo "sidead did not start" >&2; exit 1; }
cat "$daemon_log"
sleep 1
kill -0 "$daemon" || { echo "sidead exited" >&2; exit 1; }
