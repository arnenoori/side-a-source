#!/usr/bin/env bash
# The end-to-end check for sidead, from a Mac: a real sidead runs in a Linux container (swift:6.2-noble with tmux and
# python3), and Daemon/Probe, a client built on SideARemoteKit (the library the iPhone app uses), pairs with it over the
# forwarded port, lists sessions, starts a hosted session whose agent is a stand-in for Claude Code
# (Daemon/Tests/Fixtures/fake-claude-live.py, never the real CLI), replies to it, and watches the transcript grow.
#   scripts/linux-e2e.sh            this machine's architecture
#   scripts/linux-e2e.sh --amd64    under linux/amd64 emulation, where this machine is not one (--arm64 likewise)
#   SIDEA_E2E_RELAY=http://127.0.0.1:8799 scripts/linux-e2e.sh
#                                   then also through a relay running on this Mac (relay/ under `wrangler dev`): sidead gets --relay, and a
#                                   second probe pairs and works with no direct address, only through the tunnel
#   scripts/linux-e2e.sh --package dist/linux/side-a-daemon-<version>-linux-<arch>.tar.gz
#                                   instead of building sidead, install the tarball (scripts/package-sidead.sh) with its install.sh in a clean
#                                   ubuntu:24.04 that has only tmux and python3, and check that one
# Exits 0 only when the probe saw every step.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "linux-e2e.sh: run it on a Mac; the probe uses Network.framework." >&2; exit 1; }
case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
package=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --amd64) arch=amd64; shift ;;
    --arm64) arch=arm64; shift ;;
    --package) package="${2:?--package needs a tarball}"; shift 2 ;;
    *) echo "usage: scripts/linux-e2e.sh [--amd64|--arm64] [--package TARBALL]" >&2; exit 2 ;;
  esac
done
command -v docker >/dev/null || { echo "linux-e2e.sh: docker is not installed or not running." >&2; exit 1; }

port="${SIDEA_E2E_PORT:-47840}"
name="sidea-e2e-$$"
volume="sidea-linux-work-$arch"
log="$(mktemp -d "${TMPDIR:-/tmp}/sidea-e2e.XXXXXX")"
cleanup() {
  local code=$?
  [[ $code == 0 ]] || docker exec "$name" cat /root/sidead.log 2>/dev/null | tail -30
  docker rm -f "$name" >/dev/null 2>&1 || true
  [[ -z "${probe_pid:-}" ]] || kill "$probe_pid" 2>/dev/null || true
}
trap cleanup EXIT
step() { printf '\n== %s\n' "$*"; }

bin=/work/.build/daemon/release/sidead
fixture=/work/Daemon/Tests/Fixtures/fake-claude-live.py
if [[ -z "$package" ]]; then
  step "starting a swift:6.2-noble container ($arch) and building sidead"
  docker volume create "$volume" >/dev/null
  docker run -d --name "$name" --platform "linux/$arch" -p "127.0.0.1:$port:$port" -v "$PWD":/src:ro -v "$volume":/work swift:6.2-noble sleep infinity >/dev/null
  docker exec "$name" bash -c '
    set -euo pipefail
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends tmux python3 procps lsof >/dev/null
    cd /work
    find . -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
    tar -C /src --exclude=.build --exclude=./.git --exclude=./site --exclude=./relay --exclude=./apps --exclude=node_modules -cf - . | tar -C /work -xf -
    swift build --package-path Daemon --scratch-path /work/.build/daemon -c release --product sidead 2>&1 | tail -3
    mkdir -p /root/work /root/userhome /root/state'
else
  [[ -f "$package" ]] || { echo "linux-e2e.sh: $package isn't a file." >&2; exit 1; }
  package="$(cd "$(dirname "$package")" && pwd)/$(basename "$package")"
  step "a clean ubuntu:24.04 ($arch) with tmux and python3, and the package installed with its install.sh"
  docker run -d --name "$name" --platform "linux/$arch" -p "127.0.0.1:$port:$port" -v "$PWD":/src:ro -v "$package":/package.tar.gz:ro ubuntu:24.04 sleep infinity >/dev/null
  docker exec "$name" bash -c '
    set -euo pipefail
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends tmux python3 procps lsof ca-certificates >/dev/null
    mkdir -p /root/work /root/userhome /root/state /tmp/pkg
    tar -C /tmp/pkg -xzf /package.tar.gz
    cd /tmp/pkg/side-a-daemon-*
    # What a person with a bare Ubuntu would see first: install.sh names the missing library, and they install it.
    HOME=/root/userhome ./install.sh --no-service 2>&1 | head -3 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libcurl4t64 >/dev/null
    HOME=/root/userhome ./install.sh --no-service'
  bin=/root/userhome/.local/bin/sidead
  fixture=/src/Daemon/Tests/Fixtures/fake-claude-live.py
fi

relay_args="--no-relay"
if [[ -n "${SIDEA_E2E_RELAY:-}" ]]; then
  relay_args="--relay http://host.docker.internal:${SIDEA_E2E_RELAY##*:}"
fi

step "running sidead in the container"
docker exec -d -e HOME=/root/userhome -e SIDEAD_CLAUDE="python3 $fixture" -e FAKE_CLAUDE_WORK=1 -e TERM=xterm-256color -e SIDEAD_TUNNEL_TRACE=1 "$name" \
  bash -c "$bin run --state-dir /root/state --port $port --listen 0.0.0.0 --no-discover --project /root/work $relay_args > /root/sidead.log 2>&1"
for _ in $(seq 1 100); do docker exec "$name" grep -q listening /root/sidead.log 2>/dev/null && break; sleep 0.2; done
docker exec "$name" cat /root/sidead.log
docker exec "$name" "$bin" status --state-dir /root/state

pair_and_probe() {
  local title="$1"; shift
  step "sidead pair: $title (the person at the computer confirms when the phone asks)"
  local out
  out="$(mktemp "$log/pair.XXXXXX")"
  # The feeder watches a copy that a second loop refreshes, so nothing reads and writes one file in a pipeline.
  ( while ! grep -q "wants to pair" "$out"; do sleep 0.2; done; sleep 1; echo y ) |
    docker exec -i "$name" "$bin" pair --state-dir /root/state >"$out.raw" 2>&1 &
  probe_pid=$!
  ( while kill -0 "$probe_pid" 2>/dev/null; do cp "$out.raw" "$out" 2>/dev/null || true; sleep 0.1; done; cp "$out.raw" "$out" 2>/dev/null || true ) &
  for _ in $(seq 1 100); do grep -q "^Link" "$out" && break; sleep 0.2; done
  local link
  link="$(sed -n 's/^Link  //p' "$out" | head -1)"
  [[ -n "$link" ]] || { cat "$out"; echo "linux-e2e.sh: sidead pair printed no link" >&2; exit 1; }
  sed -n '1,40p' "$out"
  step "the probe, $title: pair, list, start, reply, transcript"
  swift run --package-path Daemon/Probe sidea-probe --link "$link" "$@" --cwd /root/work
  wait "$probe_pid" 2>/dev/null || true
  probe_pid=""
}

pair_and_probe "direct" --connect "127.0.0.1:$port"
if [[ -n "${SIDEA_E2E_RELAY:-}" ]]; then
  docker exec "$name" "$bin" status --state-dir /root/state
  pair_and_probe "through the relay tunnel only" --relay-only --relay-url "$SIDEA_E2E_RELAY"
fi

step "the container's sessions after the probe ended its own"
docker exec "$name" "$bin" devices --state-dir /root/state
printf '\nlinux-e2e: every step held (%s)\n' "$arch"
