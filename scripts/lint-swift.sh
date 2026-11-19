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
