#!/usr/bin/env bash
# Lints every Swift file with SwiftLint (config: .swiftlint.yml). Violations already in the baseline
# (.swiftlint-baseline.json) are tolerated; anything new fails, warnings included.
#   scripts/lint-swift.sh             what the gate runs
#   scripts/lint-swift.sh --no-baseline   every violation, to work the backlog down
#   scripts/lint-swift.sh --rebaseline    after fixing some, shrink the baseline to what is left
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v swiftlint >/dev/null; then
  echo "lint-swift.sh: swiftlint is not installed. Install it with: brew install swiftlint" >&2
  exit 1
fi
baseline=.swiftlint-baseline.json
# SwiftLint 0.65 does not match its baseline (which stores paths relative to the checkout) for a checkout whose real
# path is under /private/var (which is $TMPDIR), /private/tmp or /private/etc, even when entered by the real path:
# every baselined violation (about 445) then reports as new. Measured on the same commit, same command.
if [[ -f "$baseline" && "${1:-}" != --no-baseline && "$(pwd -P)" =~ ^/private/(var|tmp|etc)(/|$) ]]; then
  echo "lint-swift.sh: $(pwd -P) is under /private/{var,tmp,etc}, where swiftlint cannot match $baseline and would report every baselined violation as new. Lint from a checkout elsewhere (a git worktree under your home directory works)." >&2
  exit 1
fi
case "${1:-}" in
  --no-baseline) exec swiftlint lint --quiet --no-cache --strict ;;
  --rebaseline)
    # It exits nonzero while there are violations, which is the point of a baseline.
    swiftlint lint --quiet --no-cache --write-baseline "$baseline" >/dev/null || true
    echo "Baseline rewritten: $baseline"
    ;;
  "") exec swiftlint lint --quiet --no-cache --strict --baseline "$baseline" ;;
  *) echo "usage: scripts/lint-swift.sh [--no-baseline | --rebaseline]" >&2; exit 2 ;;
esac
