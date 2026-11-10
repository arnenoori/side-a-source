#!/usr/bin/env bash
# The gates a change needs, on this Mac: GitHub Actions minutes aren't used for these.
# With a revision (default origin/main), runs what the files changed since then touch. --all runs everything.
set -euo pipefail
cd "$(dirname "$0")/.."
# A hook runs with GIT_DIR set, and the tests' throwaway repos would otherwise commit into this one.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; do
  if [[ -n "${!name+set}" ]]; then
    echo "check.sh: $name is still set, and tests could write into this repository. Unset it and run again." >&2
    exit 1
  fi
done
base="${1:-origin/main}"
if [[ "$base" == --all ]]; then changed=$'bridge/\nSources/\nscripts/\nsite/\nrelay/\napps/\nPackages/'
else changed="$(git diff --name-only "$(git merge-base "$base" HEAD)" HEAD)"; fi
touches() { grep -qE "$1" <<<"$changed"; }

# SIDEA_IOS_SIMULATOR names one by id. Otherwise a booted iPhone, so nothing has to start up, then the newest available.
ios_simulator() {
  if [[ -n "${SIDEA_IOS_SIMULATOR:-}" ]]; then echo "$SIDEA_IOS_SIMULATOR"; return; fi
  xcrun simctl list devices available -j 2>/dev/null | python3 -c '
import json, re, sys
try:
    runtimes = json.load(sys.stdin)["devices"]
except ValueError:
    sys.exit()
version = lambda name: [int(part) for part in re.findall(r"\d+", name)]
phones = [(device["state"] == "Booted", version(runtime), device["udid"])
          for runtime, devices in runtimes.items() if "iOS" in runtime
          for device in devices if device["name"].startswith("iPhone")]
if phones:
    print(max(phones)[2])
'
}

# $1 is what changed. apps/ always needs them. apps/ios builds against Packages/SideAProtocol, so a
# Packages/ change needs them too, but may go without when SIDEA_IOS_TESTS=skip says so out loud.
skipped=""
ios_tests() {
  local simulator problem=""
  if ! command -v xcodegen >/dev/null; then problem="the iOS tests need xcodegen: brew install xcodegen"
  else
    simulator="$(ios_simulator || true)"
    [[ -n "$simulator" ]] || problem="no iPhone simulator is available to test on. Add one in Xcode › Settings › Components, or set SIDEA_IOS_SIMULATOR"
  fi
  if [[ -n "$problem" ]]; then
    if [[ "$1" == Packages/ && "${SIDEA_IOS_TESTS:-}" == skip ]]; then
      echo "check.sh: SKIPPED the iOS tests that Packages/ changes need, because SIDEA_IOS_TESTS=skip: $problem." >&2
      skipped=" The iOS tests were skipped (SIDEA_IOS_TESTS=skip): run them before merging."
      return
    fi
    local escape=""
    [[ "$1" == Packages/ ]] && escape=" To go without them this once, set SIDEA_IOS_TESTS=skip."
    echo "check.sh: $1 changed, and $problem.$escape" >&2
    exit 1
  fi
  (cd apps/ios && xcodegen --quiet && xcodebuild test -project SideARemote.xcodeproj -scheme SideARemote \
    -destination "id=$simulator" -derivedDataPath build/check -parallel-testing-enabled NO -quiet)
}

ran=0
if touches '^(bridge|Sources|Tests|Packages|Package\.)'; then
  python3 -m unittest discover -s bridge/tests
  rm -f Sources/SideA/Resources/*.py
  cp bridge/*.py Sources/SideA/Resources/
  swift test
  ran=1
fi
if touches '^Packages/'; then swift test --package-path Packages/SideAProtocol; ran=1; fi
if touches '^apps/'; then ios_tests apps/; ran=1
elif touches '^Packages/'; then ios_tests Packages/; ran=1; fi
if touches '^(scripts|\.github|\.githooks|\.gitattributes)'; then
  command -v actionlint >/dev/null && actionlint
  command -v shellcheck >/dev/null && shellcheck scripts/*.sh .githooks/*
  python3 -m unittest discover -s scripts/tests
  ran=1
fi
# Whatever changed: a docs or README line can leak a home path, tailnet name or token as easily as
# code, and ship.sh refuses the release if this scan of the public tree finds one.
if [[ -n "$changed" ]]; then
  public="$(mktemp -d "${TMPDIR:-/tmp}/sidea-public.XXXXXX")"
  trap 'rm -rf "$public"' EXIT
  git archive HEAD | tar -x -C "$public"
  python3 scripts/scan-public-source.py "$public"
  ran=1
fi
if touches '^site/'; then npm --prefix site ci && npm --prefix site test && npm --prefix site run build; ran=1; fi
if touches '^relay/'; then (cd relay && npm test); ran=1; fi
[[ "$ran" == 1 ]] && echo "Checks passed.$skipped" || echo "Nothing here needs checks."
