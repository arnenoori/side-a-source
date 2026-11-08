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

ios_tests() {
  command -v xcodegen >/dev/null || { echo "check.sh: apps/ changed, and the iOS tests need xcodegen: brew install xcodegen" >&2; exit 1; }
  local simulator
  simulator="$(ios_simulator || true)"
  if [[ -z "$simulator" ]]; then
    echo "check.sh: apps/ changed, and no iPhone simulator is available to test on. Add one in Xcode › Settings › Components, or set SIDEA_IOS_SIMULATOR." >&2
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
if touches '^apps/'; then ios_tests; ran=1; fi
if touches '^(scripts|\.github|\.githooks|\.gitattributes)'; then
  command -v actionlint >/dev/null && actionlint
  command -v shellcheck >/dev/null && shellcheck scripts/*.sh .githooks/*
  python3 -m unittest discover -s scripts/tests
  ran=1
fi
if touches '^site/'; then npm --prefix site ci && npm --prefix site test && npm --prefix site run build; ran=1; fi
if touches '^relay/'; then (cd relay && npm test); ran=1; fi
[[ "$ran" == 1 ]] && echo "Checks passed." || echo "Nothing here needs checks."
