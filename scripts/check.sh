#!/usr/bin/env bash
# The gates a change needs, on this Mac: GitHub Actions minutes aren't used for these.
# With a revision (default origin/main), runs what the files changed since then touch. --all runs everything.
#   check.sh [rev|--all]   check HEAD
#   check.sh --sha SHA     check that exact commit (in a clean temporary worktree unless it is HEAD)
#   check.sh --post [SHA]  post the `local-check` status for a commit that already passed here; add --wait to retry
#                          until GitHub has the commit (the pre-push hook does this, since the push hasn't landed yet)
# Proof: a run that executed every gate the change needs, on a clean tree, with nothing skipped, records the commit in
# <git-common-dir>/sidea-local-check/<sha> (shared by all worktrees) and posts a `local-check` success status when gh can.
# scripts/merge-pr.sh refuses a PR whose head commit lacks that status. A dirty tree or a skipped gate records nothing.
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
proof="$(git rev-parse --path-format=absolute --git-common-dir)/sidea-local-check"

post_status() {
  local sha="$1" attempts="${2:-1}" description error
  if [[ ! -f "$proof/$sha" ]]; then
    echo "check.sh: no passing run is recorded for $sha, so no local-check status was posted. Run: scripts/check.sh --sha $sha" >&2
    return 1
  fi
  if ! command -v gh >/dev/null; then
    echo "check.sh: gh is not installed, so the local-check status was NOT posted for $sha. Install gh, then run: scripts/check.sh --post $sha" >&2
    return 1
  fi
  description="$(cat "$proof/$sha")"
  while :; do
    if error="$(gh api "repos/{owner}/{repo}/statuses/$sha" -f state=success -f context=local-check -f "description=${description:0:140}" --silent 2>&1)"; then
      echo "check.sh: posted the local-check success status on $sha."
      return 0
    fi
    attempts=$((attempts - 1))
    if [[ "$attempts" -le 0 ]]; then
      echo "check.sh: the local-check status was NOT posted for $sha (GitHub may not have the commit yet, or gh is not signed in): $error" >&2
      echo "check.sh: once the branch is pushed, run: scripts/check.sh --post $sha" >&2
      return 1
    fi
    sleep "${SIDEA_POST_INTERVAL:-5}"
  done
}

if [[ "${1:-}" == --post ]]; then
  sha="$(git rev-parse --verify "${2:-HEAD}^{commit}")"
  attempts=1
  if [[ "${3:-}" == --wait ]]; then attempts=$(( ${SIDEA_POST_WAIT:-180} / ${SIDEA_POST_INTERVAL:-5} + 1 )); fi
  post_status "$sha" "$attempts"
  exit
fi

if [[ "${1:-}" == --sha ]]; then
  sha="$(git rev-parse --verify "${2:?usage: check.sh --sha SHA [rev]}^{commit}")"
  if [[ "$sha" == "$(git rev-parse HEAD)" ]]; then set -- "${3:-origin/main}"
  else
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/sidea-check.XXXXXX")"
    # shellcheck disable=SC2329
    cleanup() { git worktree remove --force "$scratch/tree" >/dev/null 2>&1 || true; rm -rf "$scratch"; }
    trap cleanup EXIT
    git worktree add -q --detach "$scratch/tree" "$sha"
    if [[ -d relay/node_modules ]]; then ln -s "$PWD/relay/node_modules" "$scratch/tree/relay/node_modules"; fi
    if [[ ! -x "$scratch/tree/scripts/check.sh" ]]; then echo "check.sh: $sha has no scripts/check.sh to run." >&2; exit 1; fi
    status=0
    (cd "$scratch/tree" && ./scripts/check.sh "${3:-origin/main}") || status=$?
    exit "$status"
  fi
fi

# Hooks come from core.hooksPath, which is per clone: set it here so any checkout that runs the gate gets the hook.
if [[ -x scripts/setup-hooks.sh ]]; then ./scripts/setup-hooks.sh; fi

head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
tree_clean=0
if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then tree_clean=1; fi
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
      partial=1
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
gates=()
partial=0
if touches '\.py$|^ruff\.toml$|^scripts/lint-python\.sh$'; then ./scripts/lint-python.sh; ran=1; gates+=(ruff); fi
if touches '\.swift$|^\.swiftlint|^scripts/lint-swift\.sh$'; then ./scripts/lint-swift.sh; ran=1; gates+=(swiftlint); fi
if touches '^(bridge|Sources|Tests|Packages|Package\.)'; then
  ./scripts/test-bridge.sh
  ./scripts/sync-bridge.sh
  # A setting an earlier run's tests left in the test runner's own preferences decides this run's results otherwise.
  defaults delete swiftpm-testing-helper >/dev/null 2>&1 || true
  # Hundreds of tests share this Mac with whatever else is running, and one with a wall-clock bound can lose that race
  # without being wrong. A test that fails in the full run gets one more go on its own and must pass there; an XCTest
  # failure, or a failure whose name can't be read, fails the gate as before.
  swift_log="$(mktemp)"
  if ! swift test 2>&1 | tee "$swift_log"; then
    failed="$(sed -nE 's/^✘ Test ([A-Za-z0-9_]+)\(\) failed.*/\1/p' "$swift_log" | sort -u | paste -sd'|' -)"
    if [[ -z "$failed" ]] || grep -Eq 'Executed [0-9]+ tests?, with [1-9]' "$swift_log"; then rm -f "$swift_log"; exit 1; fi
    rm -f "$swift_log"
    echo "check.sh: failed in the full run, now run on their own: ${failed//|/, }" >&2
    swift test --skip-build --filter "($failed)"
  fi
  rm -f "$swift_log"
  ran=1; gates+=(bridge-tests swift-test)
fi
if touches '^Packages/'; then swift test --package-path Packages/SideAProtocol; ran=1; gates+=(package-tests); fi
if touches '^apps/'; then ios_tests apps/; ran=1; gates+=(ios-tests)
elif touches '^Packages/'; then ios_tests Packages/; ran=1; gates+=(ios-tests); fi
if touches '^(scripts|\.github|\.githooks|\.gitattributes)'; then
  # A missing linter fails the gate like ruff and swiftlint do: skipping silently would let the pass be recorded.
  ./scripts/lint-scripts.sh
  python3 -m unittest discover -s scripts/tests
  ran=1; gates+=(actionlint shellcheck script-tests)
fi
if [[ -n "$changed" ]]; then
  public="$(mktemp -d "${TMPDIR:-/tmp}/sidea-public.XXXXXX")"
  trap 'rm -rf "$public"' EXIT
  git archive HEAD | tar -x -C "$public"
  python3 scripts/scan-public-source.py "$public"
  ran=1; gates+=(public-scan)
fi
if touches '^site/'; then npm --prefix site ci && npm --prefix site run lint && npm --prefix site test && npm --prefix site run build; ran=1; gates+=(site-lint site-tests site-build); fi
if touches '^relay/'; then (cd relay && npm run typecheck && npm run lint && npm test); ran=1; gates+=(relay-typecheck relay-lint relay-tests); fi
if [[ "$ran" == 1 ]]; then echo "Checks passed.$skipped"; else echo "Nothing here needs checks."; fi

if [[ "$partial" == 1 ]]; then echo "check.sh: not recording a pass for $head_sha: gates were skipped, so no local-check status is posted." >&2
elif [[ "$tree_clean" != 1 ]]; then echo "check.sh: not recording a pass: the tree has uncommitted changes, so this run isn't of a commit and no local-check status is posted." >&2
elif [[ "$head_sha" != "$(git rev-parse HEAD)" ]]; then echo "check.sh: not recording a pass: HEAD moved during the run." >&2
else
  mkdir -p "$proof"
  names="${gates[*]:-nothing needed}"
  printf 'check.sh vs %s: %s' "$base" "${names// /, }" >"$proof/$head_sha"
  post_status "$head_sha" || true
fi
