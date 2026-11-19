#!/usr/bin/env bash
# Lints bridge/ and scripts/ with ruff (config: ruff.toml). It only lints; nothing here formats.
#   scripts/lint-python.sh           what the gate runs
#   scripts/lint-python.sh --fix     apply the safe autofixes first
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v ruff >/dev/null; then
  echo "lint-python.sh: ruff is not installed. Install it with: brew install ruff" >&2
  exit 1
fi
case "${1:-}" in
  --fix) exec ruff check --no-cache --fix bridge scripts ;;
  "") exec ruff check --no-cache bridge scripts ;;
  *) echo "usage: scripts/lint-python.sh [--fix]" >&2; exit 2 ;;
esac
